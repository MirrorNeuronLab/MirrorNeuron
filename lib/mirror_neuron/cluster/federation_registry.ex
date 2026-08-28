defmodule MirrorNeuron.Cluster.FederationRegistry do
  @moduledoc false

  alias MirrorNeuron.Cluster.{NodeAdapter, NodeState}
  alias MirrorNeuron.Persistence.RedisStore

  @registry_version 1

  def register(node_name, peer_info, peer_auth_token)
      when is_binary(node_name) and is_map(peer_info) and is_binary(peer_auth_token) do
    node_name = String.trim(node_name)
    token = String.trim(peer_auth_token)

    with :ok <- require_peer_name(node_name),
         :ok <- require_peer_token(token),
         :ok <- reject_self(node_name),
         {:ok, local_store} <- coordination_store().coordination_store_status(),
         :ok <- require_distinct_store(local_store, peer_info) do
      peer =
        peer_info
        |> stringify_keys()
        |> Map.put("node_name", node_name)
        |> Map.put("connection_mode", "federated")
        |> Map.put("peer_auth_token", token)
        |> Map.put("registered_at", timestamp())

      update_registry(fn peers ->
        case Map.get(peers, node_name) do
          nil -> {:ok, Map.put(peers, node_name, peer), peer, "registered"}
          existing -> register_existing(peers, node_name, existing, peer)
        end
      end)
      |> case do
        {:ok, saved, status} ->
          :ok = advertise_peer(saved)
          {:ok, public_peer(saved), status}

        error ->
          error
      end
    end
  end

  def register(_node_name, _peer_info, _peer_auth_token), do: {:error, :invalid_peer}

  def fetch(node_name) do
    case Map.fetch(read_registry(), to_string(node_name)) do
      {:ok, peer} -> {:ok, peer}
      :error -> {:error, :peer_not_found}
    end
  end

  def public_fetch(node_name) do
    case fetch(node_name) do
      {:ok, peer} -> {:ok, public_peer(peer)}
      error -> error
    end
  end

  def list, do: read_registry() |> Map.values()
  def public_list, do: Enum.map(list(), &public_peer/1)
  def ready?, do: map_size(read_registry()) > 0

  def remove(node_name) do
    node_name = to_string(node_name) |> String.trim()

    result =
      update_registry(fn peers ->
        if Map.has_key?(peers, node_name) do
          {:ok, Map.delete(peers, node_name), nil, "removed"}
        else
          {:ok, peers, nil, "not_found"}
        end
      end)

    _ =
      mark_peer_state(node_name, "disconnected", %{
        "connection_mode" => "federated",
        "operator_disconnect" => true,
        "scheduling_eligible" => false,
        "job_owner_eligible" => false,
        "peer_available" => false
      })

    case result do
      {:ok, _peer, status} ->
        _ = projection_store().delete_federation_projections(node_name)
        {:ok, status}

      error ->
        error
    end
  end

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

    with :ok <- require_peer_name(owner_node),
         :ok <- require_job_id(job_id) do
      update_registry(fn peers ->
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
                "requested_at" => timestamp(),
                "updated_at" => timestamp()
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
    update_registry(fn peers ->
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

  @doc false
  def mark_job_archived(owner_node, job_id)
      when is_binary(owner_node) and is_binary(job_id) do
    case projection_store().fetch_federation_projection(owner_node, "job", job_id) do
      {:ok, projection} ->
        archived =
          projection
          |> Map.put("status", "archived")
          |> Map.put("owner_available", true)
          |> Map.put("projection_stale", false)
          |> Map.put("updated_at", timestamp())

        case projection_store().put_federation_projections(owner_node, "job", [archived]) do
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
    with {:ok, _peer} <- fetch(owner_node),
         :ok <- projection_store().delete_federation_projection(owner_node, "job", job_id),
         {:ok, runs} <- projection_store().list_federation_projections(owner_node, "run"),
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
    projected_at = timestamp()

    projected =
      Enum.map(summaries, fn summary ->
        summary
        |> stringify_keys()
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
      with {:ok, _peer} <- fetch(node_name),
           {:ok, _saved} <- apply(projection_store(), persist, [node_name, "job", projected]) do
        update_registry(fn peers ->
          peer = Map.fetch!(peers, node_name)

          saved =
            peer
            |> Map.drop(["job_projections", "run_projections"])
            |> Map.put("peer_available", true)
            |> Map.put("last_synced_at", projected_at)

          {:ok, Map.put(peers, node_name, saved), saved, "updated"}
        end)
      end

    if match?({:ok, _, _}, result), do: mark_available(node_name)
    result
  end

  def put_run_projections(node_name, summaries) when is_list(summaries) do
    store_run_projections(node_name, summaries, :merge)
  end

  def replace_run_projections(node_name, summaries) when is_list(summaries) do
    store_run_projections(node_name, summaries, :replace)
  end

  defp store_run_projections(node_name, summaries, mode) do
    projected_at = timestamp()

    projected =
      Enum.map(summaries, fn summary ->
        summary
        |> stringify_keys()
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
      with {:ok, _peer} <- fetch(node_name),
           {:ok, _saved} <- apply(projection_store(), persist, [node_name, "run", projected]) do
        update_registry(fn peers ->
          peer = Map.fetch!(peers, node_name)

          saved =
            peer
            |> Map.drop(["job_projections", "run_projections"])
            |> Map.put("peer_available", true)
            |> Map.put("last_synced_at", projected_at)

          {:ok, Map.put(peers, node_name, saved), saved, "updated"}
        end)
      end

    if match?({:ok, _, _}, result), do: mark_available(node_name)
    result
  end

  def mark_unavailable(node_name) do
    result =
      with {:ok, _peer} <- fetch(node_name),
           {:ok, jobs} <- projection_store().list_federation_projections(node_name, "job"),
           {:ok, runs} <- projection_store().list_federation_projections(node_name, "run"),
           {:ok, _jobs} <-
             projection_store().put_federation_projections(
               node_name,
               "job",
               stale_projections(jobs)
             ),
           {:ok, _runs} <-
             projection_store().put_federation_projections(
               node_name,
               "run",
               stale_projections(runs)
             ) do
        update_registry(fn peers ->
          peer = Map.fetch!(peers, node_name)

          saved =
            peer
            |> Map.drop(["job_projections", "run_projections"])
            |> Map.put("peer_available", false)

          {:ok, Map.put(peers, node_name, saved), saved, "offline"}
        end)
      end

    if match?({:ok, _, _}, result) do
      _ =
        mark_peer_state(node_name, "unavailable", %{
          "connection_mode" => "federated",
          "operator_disconnect" => false,
          "scheduling_eligible" => false,
          "job_owner_eligible" => true,
          "peer_available" => false
        })
    end

    result
  end

  def projections do
    list()
    |> Enum.flat_map(fn peer ->
      node_name = Map.get(peer, "node_name")

      case projection_store().list_federation_projections(node_name, "job") do
        {:ok, projections} ->
          projections
          |> Enum.reject(&delete_tombstoned?(peer, Map.get(&1, "job_id")))
          |> Enum.map(&project_tombstone_status(peer, &1))

        _ ->
          []
      end
    end)
  end

  def run_projections do
    list()
    |> Enum.flat_map(fn peer ->
      node_name = Map.get(peer, "node_name")

      case projection_store().list_federation_projections(node_name, "run") do
        {:ok, projections} ->
          Enum.reject(projections, &job_tombstoned?(peer, Map.get(&1, "job_id")))

        _ ->
          []
      end
    end)
  end

  def remove_projection(node_name, resource_id) do
    resource_id = to_string(resource_id)

    with {:ok, peer} <- fetch(node_name),
         :ok <- projection_store().delete_federation_projection(node_name, "job", resource_id),
         :ok <- projection_store().delete_federation_projection(node_name, "run", resource_id) do
      {:ok, public_peer(peer), "updated"}
    end
  end

  def projection(resource_id) do
    resource_id = to_string(resource_id)

    Enum.find_value(list(), fn peer ->
      node_name = Map.get(peer, "node_name")

      case projection_store().fetch_federation_projection(node_name, "job", resource_id) do
        {:ok, projection} ->
          project_tombstone_status(peer, projection)

        _ ->
          case projection_store().fetch_federation_projection(node_name, "run", resource_id) do
            {:ok, projection} -> projection
            _ -> nil
          end
      end
    end)
  end

  def projection_owner(resource_id) do
    resource_id = to_string(resource_id)

    Enum.find_value(list(), fn peer ->
      node_name = Map.get(peer, "node_name")
      direct = projection_store().fetch_federation_projection(node_name, "job", resource_id)
      run = projection_store().fetch_federation_projection(node_name, "run", resource_id)

      latest_run =
        case projection_store().list_federation_projections(node_name, "job") do
          {:ok, jobs} -> Enum.any?(jobs, &(Map.get(&1, "latest_run_id") == resource_id))
          _ -> false
        end

      if match?({:ok, _}, direct) or match?({:ok, _}, run) or latest_run, do: node_name
    end)
  end

  defp register_existing(peers, node_name, existing, peer) do
    if peer_identity(existing) == peer_identity(peer) do
      merged =
        existing
        |> Map.merge(peer)
        |> Map.drop(["job_projections", "run_projections"])

      {:ok, Map.put(peers, node_name, merged), merged, "already_registered"}
    else
      {:error, :peer_identity_conflict}
    end
  end

  defp peer_identity(peer) do
    {
      Map.get(peer, "grpc_host"),
      to_string(Map.get(peer, "grpc_port") || ""),
      get_in(peer, ["coordination_store", "identity"])
    }
  end

  defp require_peer_name(""), do: {:error, :missing_peer_name}
  defp require_peer_name(_node_name), do: :ok
  defp require_job_id(""), do: {:error, :missing_job_id}
  defp require_job_id(_job_id), do: :ok
  defp require_peer_token(""), do: {:error, :missing_peer_auth_token}
  defp require_peer_token(_token), do: :ok

  defp reject_self(node_name) do
    if node_name == to_string(NodeAdapter.self()), do: {:error, :cannot_federate_self}, else: :ok
  end

  defp require_distinct_store(local_store, peer_info) do
    local_identity =
      to_string(Map.get(local_store, "identity") || Map.get(local_store, :identity) || "")

    remote_store =
      Map.get(peer_info, "coordination_store") || Map.get(peer_info, :coordination_store) || %{}

    remote_identity =
      to_string(Map.get(remote_store, "identity") || Map.get(remote_store, :identity) || "")

    cond do
      local_identity == "" or remote_identity == "" -> {:error, :coordination_store_unavailable}
      local_identity == remote_identity -> {:error, :shared_coordination_store}
      true -> :ok
    end
  end

  defp advertise_peer(peer) do
    public = public_peer(peer)

    case mark_peer_state(Map.fetch!(public, "node_name"), "healthy", %{
           "connection_mode" => "federated",
           "operator_disconnect" => false,
           "scheduling_eligible" => false,
           "local_scheduler_eligible" => Map.get(public, "scheduling_eligible", true),
           "job_owner_eligible" => true,
           "peer_available" => true,
           "grpc_host" => Map.get(public, "grpc_host"),
           "grpc_port" => Map.get(public, "grpc_port"),
           "litellm" => Map.get(public, "litellm", %{}),
           "coordination_store" => Map.get(public, "coordination_store", %{}),
           "hardware" => Map.get(public, "hardware", %{}),
           "native_sdk_grpc" => Map.get(public, "native_sdk_grpc", %{}),
           "display_name" => Map.get(public, "display_name"),
           "hostname" => Map.get(public, "hostname"),
           "runtime_models" => Map.get(public, "runtime_models", []),
           "services" => Map.get(public, "services", [])
         }) do
      {:ok, _state} -> :ok
      error -> error
    end
  end

  defp public_peer(peer) do
    peer
    |> Map.drop([
      "peer_auth_token",
      "job_projections",
      "run_projections",
      "archive_tombstones",
      "delete_tombstones"
    ])
    |> Map.put("connection_mode", "federated")
  end

  defp mark_available(node_name) do
    mark_peer_state(node_name, "healthy", %{
      "connection_mode" => "federated",
      "operator_disconnect" => false,
      "scheduling_eligible" => false,
      "job_owner_eligible" => true,
      "peer_available" => true
    })
  end

  defp update_registry(callback) do
    :global.trans({__MODULE__, registry_path()}, fn ->
      peers = read_registry()

      case callback.(peers) do
        {:ok, updated, value, status} ->
          with :ok <- write_registry(updated), do: {:ok, value, status}

        error ->
          error
      end
    end)
  end

  defp read_registry do
    case File.read(registry_path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"peers" => peers}} when is_map(peers) -> peers
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write_registry(peers) do
    path = registry_path()
    directory = Path.dirname(path)
    temp = path <> ".tmp"

    peers =
      Map.new(peers, fn {node_name, peer} ->
        {node_name, Map.drop(peer, ["job_projections", "run_projections"])}
      end)

    with :ok <- File.mkdir_p(directory),
         :ok <-
           File.write(temp, Jason.encode!(%{"version" => @registry_version, "peers" => peers})),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp registry_path do
    home =
      case System.get_env("MN_HOME") do
        value when is_binary(value) and value != "" -> value
        _ -> Path.join(System.user_home!(), ".mn")
      end

    Path.join([home, "federation", "peers.json"])
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp coordination_store do
    Application.get_env(:mirror_neuron, :coordination_store, RedisStore)
  end

  defp projection_store do
    Application.get_env(:mirror_neuron, :federation_projection_store, RedisStore)
  end

  defp stale_projections(projections) do
    Enum.map(projections, fn projection ->
      projection
      |> Map.put("owner_available", false)
      |> Map.put("projection_stale", true)
    end)
  end

  defp job_tombstones(owner_node, operation) do
    with {:ok, peer} <- fetch(owner_node) do
      tombstones =
        peer
        |> Map.get(tombstone_key(operation), %{})
        |> Map.values()
        |> Enum.filter(&(Map.get(&1, "status") == "pending"))
        |> Enum.sort_by(&Map.get(&1, "job_id", ""))

      {:ok, tombstones}
    end
  end

  defp delete_job_run_projections(owner_node, job_id, runs) do
    runs
    |> Enum.filter(&(Map.get(&1, "job_id") == job_id))
    |> Enum.reduce_while(:ok, fn run, :ok ->
      case projection_store().delete_federation_projection(owner_node, "run", run["run_id"]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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

  defp delete_tombstoned?(peer, job_id) when is_binary(job_id) do
    match?(%{"status" => "pending"}, get_in(peer, ["delete_tombstones", job_id]))
  end

  defp delete_tombstoned?(_peer, _job_id), do: false

  defp job_tombstoned?(peer, job_id),
    do: archive_tombstoned?(peer, job_id) or delete_tombstoned?(peer, job_id)

  defp project_tombstone_status(peer, projection) do
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

  defp mark_peer_state(node_name, status, attrs) do
    existing =
      case NodeState.fetch(node_name) do
        {:ok, state} when is_map(state) -> state
        _ -> %{}
      end

    NodeState.mark(node_name, status, Map.merge(existing, attrs))
  end
end
