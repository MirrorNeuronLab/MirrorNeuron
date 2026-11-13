defmodule MirrorNeuron.Cluster.FederationRegistry.Projections do
  @moduledoc "Persists owner summaries and routes reads while honoring pending tombstones."

  alias MirrorNeuron.Cluster.FederationRegistry.Peers
  alias MirrorNeuron.Cluster.FederationRegistry.Storage
  alias MirrorNeuron.Cluster.FederationRegistry.Tombstones
  alias MirrorNeuron.Cluster.FederationRegistry.Values

  @doc false
  def mark_job_archived(owner_node, job_id)
      when is_binary(owner_node) and is_binary(job_id) do
    case Values.projection_store().fetch_federation_projection(owner_node, "job", job_id) do
      {:ok, projection} ->
        archived =
          projection
          |> Map.put("status", "archived")
          |> Map.put("owner_available", true)
          |> Map.put("projection_stale", false)
          |> Map.put("updated_at", Values.timestamp())

        case Values.projection_store().put_federation_projections(owner_node, "job", [archived]) do
          {:ok, _saved} -> {:ok, archived}
          {:error, _reason} = error -> error
        end

      {:error, :not_found} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  def mark_job_archived(_owner_node, _job_id), do: {:error, :invalid_job_projection}

  @doc false
  def mark_job_deleted(owner_node, job_id)
      when is_binary(owner_node) and is_binary(job_id) do
    with {:ok, _peer} <- Peers.fetch(owner_node),
         :ok <- Values.projection_store().delete_federation_projection(owner_node, "job", job_id),
         {:ok, runs} <- Values.projection_store().list_federation_projections(owner_node, "run"),
         :ok <- delete_job_run_projections(owner_node, job_id, runs) do
      {:ok, nil}
    end
  end

  def mark_job_deleted(_owner_node, _job_id), do: {:error, :invalid_job_projection}

  def put_projection(node_name, summaries) when is_list(summaries) do
    store_projections(node_name, summaries, :merge)
  end

  def replace_projections(node_name, summaries) when is_list(summaries) do
    store_projections(node_name, summaries, :replace)
  end

  defp store_projections(node_name, summaries, mode) do
    projected_at = Values.timestamp()

    projected =
      Enum.map(summaries, fn summary ->
        summary
        |> Values.stringify_keys()
        |> Map.put("owner_node", node_name)
        |> Map.put("owner_available", true)
        |> Map.put("projection_level", "summary")
        |> Map.put("projection_stale", false)
        |> Map.put("last_synced_at", projected_at)
      end)

    persist =
      case mode do
        :replace -> :replace_federation_projections
        :merge -> :put_federation_projections
      end

    result =
      with {:ok, _peer} <- Peers.fetch(node_name),
           {:ok, _saved} <-
             apply(Values.projection_store(), persist, [node_name, "job", projected]) do
        Storage.update_registry(fn peers ->
          peer = Map.fetch!(peers, node_name)

          saved =
            peer
            |> Map.drop(["job_projections", "run_projections"])
            |> Map.put("last_synced_at", projected_at)

          {:ok, Map.put(peers, node_name, saved), saved, "updated"}
        end)
      end

    result
  end

  def put_run_projections(node_name, summaries) when is_list(summaries) do
    store_run_projections(node_name, summaries, :merge)
  end

  def replace_run_projections(node_name, summaries) when is_list(summaries) do
    store_run_projections(node_name, summaries, :replace)
  end

  defp store_run_projections(node_name, summaries, mode) do
    projected_at = Values.timestamp()

    projected =
      Enum.map(summaries, fn summary ->
        summary
        |> Values.stringify_keys()
        |> Map.put("owner_node", node_name)
        |> Map.put("owner_available", true)
        |> Map.put("projection_level", "summary")
        |> Map.put("projection_stale", false)
        |> Map.put("last_synced_at", projected_at)
      end)

    persist =
      case mode do
        :replace -> :replace_federation_projections
        :merge -> :put_federation_projections
      end

    result =
      with {:ok, _peer} <- Peers.fetch(node_name),
           {:ok, _saved} <-
             apply(Values.projection_store(), persist, [node_name, "run", projected]) do
        Storage.update_registry(fn peers ->
          peer = Map.fetch!(peers, node_name)

          saved =
            peer
            |> Map.drop(["job_projections", "run_projections"])
            |> Map.put("last_synced_at", projected_at)

          {:ok, Map.put(peers, node_name, saved), saved, "updated"}
        end)
      end

    result
  end

  def projections do
    Peers.list()
    |> Enum.flat_map(fn peer ->
      node_name = Map.get(peer, "node_name")

      case Values.projection_store().list_federation_projections(node_name, "job") do
        {:ok, projections} ->
          projections
          |> Enum.reject(&Tombstones.delete_tombstoned?(peer, Map.get(&1, "job_id")))
          |> Enum.map(&Tombstones.project_tombstone_status(peer, &1))

        _ ->
          []
      end
    end)
  end

  def run_projections do
    Peers.list()
    |> Enum.flat_map(fn peer ->
      node_name = Map.get(peer, "node_name")

      case Values.projection_store().list_federation_projections(node_name, "run") do
        {:ok, projections} ->
          Enum.reject(projections, &Tombstones.job_tombstoned?(peer, Map.get(&1, "job_id")))

        _ ->
          []
      end
    end)
  end

  def remove_projection(node_name, resource_id) do
    resource_id = to_string(resource_id)

    with {:ok, peer} <- Peers.fetch(node_name),
         :ok <-
           Values.projection_store().delete_federation_projection(node_name, "job", resource_id),
         :ok <-
           Values.projection_store().delete_federation_projection(node_name, "run", resource_id) do
      {:ok, Peers.public_peer(peer), "updated"}
    end
  end

  def projection(resource_id) do
    resource_id = to_string(resource_id)

    Enum.find_value(Peers.list(), fn peer ->
      node_name = Map.get(peer, "node_name")

      case Values.projection_store().fetch_federation_projection(node_name, "job", resource_id) do
        {:ok, projection} ->
          Tombstones.project_tombstone_status(peer, projection)

        _ ->
          case Values.projection_store().fetch_federation_projection(
                 node_name,
                 "run",
                 resource_id
               ) do
            {:ok, projection} -> projection
            _ -> nil
          end
      end
    end)
  end

  def projection_owner(resource_id) do
    resource_id = to_string(resource_id)

    Enum.find_value(Peers.list(), fn peer ->
      node_name = Map.get(peer, "node_name")

      direct =
        Values.projection_store().fetch_federation_projection(node_name, "job", resource_id)

      run = Values.projection_store().fetch_federation_projection(node_name, "run", resource_id)

      latest_run =
        case Values.projection_store().list_federation_projections(node_name, "job") do
          {:ok, jobs} -> Enum.any?(jobs, &(Map.get(&1, "latest_run_id") == resource_id))
          _ -> false
        end

      if match?({:ok, _}, direct) or match?({:ok, _}, run) or latest_run, do: node_name
    end)
  end

  defp delete_job_run_projections(owner_node, job_id, runs) do
    runs
    |> Enum.filter(&(Map.get(&1, "job_id") == job_id))
    |> Enum.reduce_while(:ok, fn run, :ok ->
      case Values.projection_store().delete_federation_projection(
             owner_node,
             "run",
             run["run_id"]
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
