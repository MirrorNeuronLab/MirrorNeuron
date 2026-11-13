defmodule MirrorNeuron.Cluster.FederationRegistry.Availability do
  @moduledoc "Tracks peer reachability separately from stale job and run observations."

  alias MirrorNeuron.Cluster.NodeState
  alias MirrorNeuron.Cluster.FederationRegistry.Peers
  alias MirrorNeuron.Cluster.FederationRegistry.Storage
  alias MirrorNeuron.Cluster.FederationRegistry.Values

  def mark_projections_stale(node_name) do
    with {:ok, _peer} <- Peers.fetch(node_name),
         {:ok, jobs} <- Values.projection_store().list_federation_projections(node_name, "job"),
         {:ok, runs} <- Values.projection_store().list_federation_projections(node_name, "run"),
         {:ok, _} <-
           Values.projection_store().put_federation_projections(
             node_name,
             "job",
             Enum.map(jobs, &Map.put(&1, "projection_stale", true))
           ),
         {:ok, _} <-
           Values.projection_store().put_federation_projections(
             node_name,
             "run",
             Enum.map(runs, &Map.put(&1, "projection_stale", true))
           ) do
      :ok
    end
  end

  def mark_unavailable(node_name) do
    result =
      with {:ok, _peer} <- Peers.fetch(node_name) do
        Storage.update_registry(fn peers ->
          peer = Map.fetch!(peers, node_name)
          saved = Map.put(peer, "peer_available", false)
          {:ok, Map.put(peers, node_name, saved), saved, "offline"}
        end)
      end

    if match?({:ok, _, _}, result) do
      _ = set_projection_owner_available(node_name, false)
      _ = mark_projections_stale(node_name)

      state_result =
        mark_peer_state(node_name, "unavailable", %{
          "connection_mode" => "federated",
          "operator_disconnect" => false,
          "scheduling_eligible" => false,
          "job_owner_eligible" => true,
          "peer_available" => false
        })

      if match?({:ok, _}, state_result), do: result, else: state_result
    else
      result
    end
  end

  def mark_available(node_name) do
    result =
      with {:ok, _peer} <- Peers.fetch(node_name) do
        Storage.update_registry(fn peers ->
          peer = Map.fetch!(peers, node_name)
          saved = Map.put(peer, "peer_available", true)
          {:ok, Map.put(peers, node_name, saved), saved, "online"}
        end)
      end

    if match?({:ok, _, _}, result) do
      state_result =
        mark_peer_state(node_name, "healthy", %{
          "connection_mode" => "federated",
          "operator_disconnect" => false,
          "scheduling_eligible" => false,
          "job_owner_eligible" => true,
          "peer_available" => true
        })

      _ = set_projection_owner_available(node_name, true)
      if match?({:ok, _}, state_result), do: result, else: state_result
    else
      result
    end
  end

  defp set_projection_owner_available(node_name, available) do
    with {:ok, jobs} <- Values.projection_store().list_federation_projections(node_name, "job"),
         {:ok, runs} <- Values.projection_store().list_federation_projections(node_name, "run"),
         {:ok, _} <-
           Values.projection_store().put_federation_projections(
             node_name,
             "job",
             Enum.map(jobs, &Map.put(&1, "owner_available", available))
           ),
         {:ok, _} <-
           Values.projection_store().put_federation_projections(
             node_name,
             "run",
             Enum.map(runs, &Map.put(&1, "owner_available", available))
           ) do
      :ok
    end
  end

  def mark_peer_state(node_name, status, attrs) do
    existing =
      case NodeState.fetch(node_name) do
        {:ok, state} when is_map(state) -> state
        _ -> %{}
      end

    NodeState.mark(node_name, status, Map.merge(existing, attrs))
  end
end
