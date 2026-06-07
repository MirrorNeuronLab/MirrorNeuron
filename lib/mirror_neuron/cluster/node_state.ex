defmodule MirrorNeuron.Cluster.NodeState do
  @moduledoc false

  alias MirrorNeuron.Cluster.Hardware
  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Persistence.RedisStore

  @active_statuses ["healthy", "joining"]
  @operator_statuses ["maintenance", "draining"]
  @inactive_statuses ["disconnected", "maintenance", "draining", "offline", "quarantined"]

  def mark(node, status, attrs \\ %{}) do
    node_name = to_string(node)
    {status, attrs} = preserve_operator_disconnect(node_name, status, attrs)

    attrs =
      attrs
      |> Map.put("status", to_string(status))
      |> Map.put("node", node_name)

    RedisStore.persist_node_state(node_name, attrs)
  end

  def mark_connected(node, attrs \\ %{}) do
    node_name = to_string(node)

    case fetch(node_name) do
      {:ok, %{"operator_disconnect" => true} = existing} ->
        if Map.get(attrs, "operator_disconnect") == false do
          mark(
            node_name,
            "healthy",
            Map.merge(existing, attrs) |> Map.put("scheduling_eligible", true)
          )
        else
          mark(node_name, Map.get(existing, "status", "disconnected"), Map.merge(existing, attrs))
        end

      {:ok, %{"status" => status} = existing} when status in @operator_statuses ->
        mark(node_name, status, Map.merge(existing, attrs))

      {:ok, %{"scheduling_eligible" => false} = existing} ->
        mark(node_name, Map.get(existing, "status", "maintenance"), Map.merge(existing, attrs))

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

  def fetch(node), do: RedisStore.fetch_node_state(to_string(node))

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
    case RedisStore.list_node_states() do
      {:ok, states} -> states
      {:error, _reason} -> []
    end
  end

  def advertise_self(status \\ "healthy", attrs \\ %{}) do
    hardware = map_get(attrs, "hardware") || Hardware.info()

    attrs =
      %{"node_role" => MirrorNeuron.Application.node_role()}
      |> Map.put("hardware", hardware)
      |> Map.merge(Profile.node_advertisement())
      |> Map.merge(MirrorNeuron.Artifacts.Registry.node_advertisement())
      |> Map.merge(attrs)
      |> merge_capabilities(hardware)

    ModelServices.advertise_env_models(Node.self())

    if to_string(status) == "healthy" do
      mark_connected(Node.self(), Map.merge(attrs, %{"self" => Map.get(attrs, "self", true)}))
    else
      mark(Node.self(), status, attrs)
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
    if node in [Node.self() | Node.list()], do: "healthy", else: "offline"
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
