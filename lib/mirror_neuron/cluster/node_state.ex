defmodule MirrorNeuron.Cluster.NodeState do
  @moduledoc false

  alias MirrorNeuron.Cluster.Hardware
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Persistence.RedisStore

  @active_statuses ["healthy", "joining"]
  @operator_statuses ["maintenance", "draining"]
  @inactive_statuses ["disconnected", "maintenance", "draining", "offline", "quarantined"]
  @runtime_status_domains ["jobs", "models"]

  def mark(node, status, attrs \\ %{}) do
    node_name = to_string(node)
    {status, attrs} = preserve_operator_disconnect(node_name, status, attrs)

    attrs =
      attrs
      |> Map.put("status", to_string(status))
      |> Map.put("node", node_name)

    store().persist_node_state(node_name, attrs)
  end

  def mark_connected(node, attrs \\ %{}) do
    node_name = to_string(node)

    case fetch(node_name) do
      {:ok, %{"operator_disconnect" => true} = existing} ->
        if clears_cordon?(attrs) do
          mark(
            node_name,
            "healthy",
            existing
            |> Map.merge(attrs)
            |> Map.put("operator_disconnect", false)
            |> Map.put("scheduling_eligible", true)
          )
        else
          mark(node_name, Map.get(existing, "status", "disconnected"), Map.merge(existing, attrs))
        end

      {:ok, %{"status" => status} = existing} when status in @operator_statuses ->
        mark(
          node_name,
          status,
          Map.merge(existing, attrs) |> Map.put("scheduling_eligible", false)
        )

      {:ok, %{"scheduling_eligible" => false} = existing} ->
        if clears_cordon?(attrs) do
          mark(
            node_name,
            "healthy",
            existing
            |> Map.merge(attrs)
            |> Map.put("operator_disconnect", false)
            |> Map.put("scheduling_eligible", true)
          )
        else
          mark(node_name, Map.get(existing, "status", "maintenance"), Map.merge(existing, attrs))
        end

      _ ->
        mark(node_name, "healthy", attrs)
    end
  end

  def status(node) do
    case fetch(node) do
      {:ok, %{"status" => status}} -> status
      _ -> default_status(node)
    end
  end

  def fetch(node), do: store().fetch_node_state(to_string(node))

  def active?(node), do: status(node) in @active_statuses
  def inactive?(node), do: status(node) in @inactive_statuses

  def schedulable?(node) do
    case fetch(node) do
      {:ok, state} -> schedulable_state?(state)
      _ -> active?(node)
    end
  end

  def schedulable_state?(%{"status" => status, "scheduling_eligible" => eligible}) do
    status in @active_statuses and eligible != false
  end

  def schedulable_state?(%{"status" => status}), do: status in @active_statuses
  def schedulable_state?(_state), do: true

  def operator_disconnected_state?(%{"operator_disconnect" => true}), do: true
  def operator_disconnected_state?(_state), do: false

  def list do
    case store().list_node_states() do
      {:ok, states} -> states
      {:error, _reason} -> []
    end
  end

  def publish_runtime_status(domain, revision, status)
      when is_binary(domain) and is_binary(revision) and is_map(status) do
    domain = String.trim(domain)
    revision = String.trim(revision)

    cond do
      domain not in @runtime_status_domains ->
        {:error,
         "runtime status domain must be one of #{Enum.join(@runtime_status_domains, ", ")}"}

      revision == "" ->
        {:error, "runtime status revision is required"}

      true ->
        publish_runtime_status_snapshot(domain, revision, status)
    end
  end

  def publish_runtime_status(_domain, _revision, _status) do
    {:error, "runtime status requires a domain, revision, and object status"}
  end

  def runtime_status_events(count \\ 100) do
    store().read_node_runtime_status_events(to_string(NodeAdapter.self()), count)
  end

  def ack_runtime_status_events(event_ids) when is_list(event_ids) do
    store().ack_node_runtime_status_events(to_string(NodeAdapter.self()), event_ids)
  end

  def cluster_runtime_status do
    store().runtime_status_snapshots(["jobs", "schedules", "deployments"])
  end

  def cluster_runtime_status_events(count \\ 100) do
    store().read_node_cluster_runtime_status_events(to_string(NodeAdapter.self()), count)
  end

  def ack_cluster_runtime_status_events(event_ids) when is_list(event_ids) do
    store().ack_node_cluster_runtime_status_events(to_string(NodeAdapter.self()), event_ids)
  end

  def advertise_self(status \\ "healthy", attrs \\ %{}) do
    hardware = map_get(attrs, "hardware") || Hardware.info()

    attrs =
      %{"node_role" => MirrorNeuron.Application.node_role()}
      |> Map.put("hardware", hardware)
      |> Map.merge(Profile.node_advertisement())
      |> Map.merge(MirrorNeuron.Artifacts.Registry.node_advertisement())
      |> Map.merge(attrs)
      |> Map.put_new("operator_disconnect", false)
      |> Map.put_new("scheduling_eligible", true)
      |> merge_capabilities(hardware)

    ModelServices.advertise_env_models(NodeAdapter.self())

    if to_string(status) == "healthy" do
      mark_connected(
        NodeAdapter.self(),
        Map.merge(attrs, %{"self" => Map.get(attrs, "self", true)})
      )
    else
      mark(NodeAdapter.self(), status, attrs)
    end
  end

  def mark_profile_health(node, profile_name, status, attrs \\ %{}) do
    node_name = to_string(node)
    profile_name = to_string(profile_name)

    existing =
      case fetch(node_name) do
        {:ok, state} -> state
        {:error, _reason} -> %{"node" => node_name}
      end

    profile_health =
      existing
      |> Map.get("profile_health", %{})
      |> Map.put(profile_name, Map.merge(%{"status" => to_string(status)}, attrs))

    profiles =
      case to_string(status) do
        "healthy" ->
          [profile_name | Map.get(existing, "profiles", [])] |> Enum.uniq() |> Enum.sort()

        _ ->
          existing
          |> Map.get("profiles", [])
          |> Enum.reject(&(&1 == profile_name))
      end

    mark(node_name, Map.get(existing, "status", default_status(node)), %{
      "profiles" => profiles,
      "profile_health" => profile_health
    })
  end

  defp default_status(node) do
    if node in [NodeAdapter.self() | NodeAdapter.list()], do: "healthy", else: "offline"
  end

  defp publish_runtime_status_snapshot(domain, revision, status) do
    node_name = NodeAdapter.self() |> to_string()

    existing =
      case fetch(node_name) do
        {:ok, state} when is_map(state) -> state
        _ -> %{}
      end

    runtime_status =
      case Map.get(existing, "runtime_status") do
        statuses when is_map(statuses) -> statuses
        _ -> %{}
      end

    current = Map.get(runtime_status, domain)

    if is_map(current) and Map.get(current, "revision") == revision and
         Map.get(current, "status") == status do
      {:ok, runtime_status_ack(node_name, domain, revision, "unchanged", current)}
    else
      snapshot = %{
        "revision" => revision,
        "reported_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "status" => status
      }

      with {:ok, _state} <- store().persist_node_runtime_status(node_name, domain, snapshot) do
        {:ok, runtime_status_ack(node_name, domain, revision, "accepted", snapshot)}
      end
    end
  end

  defp runtime_status_ack(node_name, domain, revision, status, snapshot) do
    %{
      "node" => node_name,
      "domain" => domain,
      "revision" => revision,
      "status" => status,
      "snapshot" => snapshot
    }
  end

  defp store do
    Application.get_env(:mirror_neuron, :node_state_store, RedisStore)
  end

  defp preserve_operator_disconnect(node_name, status, attrs) do
    if clears_operator_disconnect?(attrs) do
      {status, attrs}
    else
      case fetch(node_name) do
        {:ok, %{"operator_disconnect" => true} = existing} ->
          preserved =
            existing
            |> Map.merge(attrs)
            |> Map.put("operator_disconnect", true)
            |> Map.put("scheduling_eligible", false)

          {Map.get(existing, "status", "disconnected"), preserved}

        _ ->
          {status, attrs}
      end
    end
  end

  defp clears_operator_disconnect?(attrs) do
    Map.get(attrs, "operator_disconnect") == false or
      Map.get(attrs, :operator_disconnect) == false
  end

  defp clears_cordon?(attrs) do
    clears_operator_disconnect?(attrs) or
      Map.get(attrs, "scheduling_eligible") == true or
      Map.get(attrs, :scheduling_eligible) == true
  end

  defp merge_capabilities(attrs, hardware) do
    capabilities =
      []
      |> Kernel.++(list_value(map_get(attrs, "capabilities")))
      |> Kernel.++(list_value(map_get(hardware, "capabilities")))
      |> Kernel.++(
        hardware
        |> map_get("devices")
        |> List.wrap()
        |> Enum.flat_map(&list_value(map_get(&1, "capabilities")))
      )
      |> Enum.map(&normalize_capability/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    Map.put(attrs, "capabilities", capabilities)
  end

  defp list_value(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp list_value(value) when is_binary(value), do: String.split(value, ",", trim: true)
  defp list_value(nil), do: []
  defp list_value(value), do: [to_string(value)]

  defp normalize_capability(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp map_get(map, key) when is_map(map) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      existing_atom_value(map, key)
    end
  end

  defp map_get(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    atom = String.to_existing_atom(to_string(key))
    if Map.has_key?(map, atom), do: Map.get(map, atom)
  rescue
    ArgumentError -> nil
  end
end
