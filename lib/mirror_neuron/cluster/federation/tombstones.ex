defmodule MirrorNeuron.Cluster.FederationRegistry.Tombstones do
  @moduledoc "Persists deferred archive/delete operations and fences stale projections."

  alias MirrorNeuron.Cluster.FederationRegistry.Peers
  alias MirrorNeuron.Cluster.FederationRegistry.Storage
  alias MirrorNeuron.Cluster.FederationRegistry.Values

  @doc false
  def queue_archive_tombstone(owner_node, job_id, expected_revision)
      when is_binary(owner_node) and is_binary(job_id) and is_integer(expected_revision) do
    queue_job_tombstone(owner_node, job_id, expected_revision, "archive")
  end

  def queue_archive_tombstone(_owner_node, _job_id, _expected_revision),
    do: {:error, :invalid_archive_tombstone}

  @doc false
  def queue_delete_tombstone(owner_node, job_id, expected_revision)
      when is_binary(owner_node) and is_binary(job_id) and is_integer(expected_revision) do
    queue_job_tombstone(owner_node, job_id, expected_revision, "delete")
  end

  def queue_delete_tombstone(_owner_node, _job_id, _expected_revision),
    do: {:error, :invalid_delete_tombstone}

  defp queue_job_tombstone(owner_node, job_id, expected_revision, operation) do
    owner_node = String.trim(owner_node)
    job_id = String.trim(job_id)

    with :ok <- Peers.require_peer_name(owner_node),
         :ok <- Peers.require_job_id(job_id) do
      Storage.update_registry(fn peers ->
        with {:ok, peer} <- Map.fetch(peers, owner_node) do
          tombstone_key = tombstone_key(operation)
          tombstones = Map.get(peer, tombstone_key, %{})

          tombstone =
            Map.get(tombstones, job_id) ||
              %{
                "job_id" => job_id,
                "owner_node" => owner_node,
                "expected_revision" => expected_revision,
                "operation" => operation,
                "status" => "pending",
                "requested_at" => Values.timestamp(),
                "updated_at" => Values.timestamp()
              }

          updated_peer =
            peer
            |> Map.put(tombstone_key, Map.put(tombstones, job_id, tombstone))
            |> clear_superseded_tombstone(operation, job_id)

          {:ok, Map.put(peers, owner_node, updated_peer), tombstone, "#{operation}_queued"}
        else
          :error -> {:error, :peer_not_found}
        end
      end)
      |> case do
        {:ok, tombstone, _status} -> {:ok, tombstone}
        error -> error
      end
    end
  end

  @doc false
  def archive_tombstones(owner_node) when is_binary(owner_node) do
    job_tombstones(owner_node, "archive")
  end

  def archive_tombstones(_owner_node), do: {:error, :invalid_owner_node}

  @doc false
  def delete_tombstones(owner_node) when is_binary(owner_node) do
    job_tombstones(owner_node, "delete")
  end

  def delete_tombstones(_owner_node), do: {:error, :invalid_owner_node}

  @doc false
  def clear_archive_tombstone(owner_node, job_id)
      when is_binary(owner_node) and is_binary(job_id) do
    clear_job_tombstone(owner_node, job_id, "archive")
  end

  def clear_archive_tombstone(_owner_node, _job_id), do: {:error, :invalid_archive_tombstone}

  @doc false
  def clear_delete_tombstone(owner_node, job_id)
      when is_binary(owner_node) and is_binary(job_id) do
    clear_job_tombstone(owner_node, job_id, "delete")
  end

  def clear_delete_tombstone(_owner_node, _job_id), do: {:error, :invalid_delete_tombstone}

  defp clear_job_tombstone(owner_node, job_id, operation) do
    Storage.update_registry(fn peers ->
      with {:ok, peer} <- Map.fetch(peers, owner_node) do
        tombstone_key = tombstone_key(operation)
        tombstones = Map.get(peer, tombstone_key, %{})
        updated_peer = Map.put(peer, tombstone_key, Map.delete(tombstones, job_id))
        {:ok, Map.put(peers, owner_node, updated_peer), nil, "#{operation}_tombstone_cleared"}
      else
        :error -> {:error, :peer_not_found}
      end
    end)
    |> case do
      {:ok, _value, _status} -> :ok
      error -> error
    end
  end

  defp job_tombstones(owner_node, operation) do
    with {:ok, peer} <- Peers.fetch(owner_node) do
      tombstones =
        peer
        |> Map.get(tombstone_key(operation), %{})
        |> Map.values()
        |> Enum.filter(&(Map.get(&1, "status") == "pending"))
        |> Enum.sort_by(&Map.get(&1, "job_id", ""))

      {:ok, tombstones}
    end
  end

  defp tombstone_key("archive"), do: "archive_tombstones"

  defp tombstone_key("delete"), do: "delete_tombstones"

  defp clear_superseded_tombstone(peer, "delete", job_id) do
    peer
    |> Map.get("archive_tombstones", %{})
    |> then(&Map.put(peer, "archive_tombstones", Map.delete(&1, job_id)))
  end

  defp clear_superseded_tombstone(peer, _operation, _job_id), do: peer

  defp archive_tombstoned?(peer, job_id) when is_binary(job_id) do
    match?(%{"status" => "pending"}, get_in(peer, ["archive_tombstones", job_id]))
  end

  defp archive_tombstoned?(_peer, _job_id), do: false

  def delete_tombstoned?(peer, job_id) when is_binary(job_id) do
    match?(%{"status" => "pending"}, get_in(peer, ["delete_tombstones", job_id]))
  end

  def delete_tombstoned?(_peer, _job_id), do: false

  def job_tombstoned?(peer, job_id),
    do: archive_tombstoned?(peer, job_id) or delete_tombstoned?(peer, job_id)

  def project_tombstone_status(peer, projection) do
    job_id = Map.get(projection, "job_id")

    case pending_tombstone(peer, job_id) do
      %{"status" => "pending"} = tombstone ->
        projection
        |> Map.put("status", "#{tombstone["operation"] || "archive"}_pending")
        |> Map.put("updated_at", tombstone["updated_at"] || tombstone["requested_at"])

      _ ->
        projection
    end
  end

  defp pending_tombstone(peer, job_id) do
    get_in(peer, ["delete_tombstones", job_id]) ||
      get_in(peer, ["archive_tombstones", job_id])
  end
end
