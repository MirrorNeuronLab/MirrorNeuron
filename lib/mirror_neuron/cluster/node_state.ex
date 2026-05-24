defmodule MirrorNeuron.Cluster.NodeState do
  @moduledoc false

  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.Persistence.RedisStore

  @active_statuses ["healthy", "joining"]
  @operator_statuses ["maintenance", "draining"]
  @inactive_statuses ["disconnected", "maintenance", "draining", "offline", "quarantined"]

  def mark(node, status, attrs \\ %{}) do
    node_name = to_string(node)

    attrs =
      attrs
      |> Map.put("status", to_string(status))
      |> Map.put("node", node_name)

    RedisStore.persist_node_state(node_name, attrs)
  end

  def mark_connected(node, attrs \\ %{}) do
    node_name = to_string(node)

    case fetch(node_name) do
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

  def list do
    case RedisStore.list_node_states() do
      {:ok, states} -> states
      {:error, _reason} -> []
    end
  end

  def advertise_self(status \\ "healthy", attrs \\ %{}) do
    attrs =
      %{"node_role" => MirrorNeuron.Application.node_role()}
      |> Map.merge(Profile.node_advertisement())
      |> Map.merge(attrs)

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
end
