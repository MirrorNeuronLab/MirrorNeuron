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

  def mark_unavailable(node_name), do: mark_availability(node_name, false)
  def mark_available(node_name), do: mark_availability(node_name, true)

  defp mark_availability(node_name, available) do
    Storage.update_registry(
      fn peers ->
        case Map.fetch(peers, node_name) do
          {:ok, peer} ->
            saved = Map.put(peer, "peer_available", available)

            {:ok, Map.put(peers, node_name, saved), saved,
             if(available, do: "online", else: "offline")}

          :error ->
            {:error, :peer_not_found}
        end
      end,
      fn saved, status ->
        # The registry and its node projection share the mutation lock. A late
        # probe cannot overwrite a completed removal with a healthy node row.
        with {:ok, _} <-
               mark_peer_state(node_name, if(available, do: "healthy", else: "unavailable"), %{
                 "connection_mode" => "federated",
                 "operator_disconnect" => false,
                 "scheduling_eligible" => false,
                 "job_owner_eligible" => true,
                 "peer_available" => available
               }),
             :ok <- set_projection_owner_available(node_name, available),
             :ok <- if(available, do: :ok, else: mark_projections_stale(node_name)) do
          {:ok, saved, status}
        end
      end
    )
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
