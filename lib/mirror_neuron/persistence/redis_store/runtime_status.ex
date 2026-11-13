defmodule MirrorNeuron.Persistence.RedisStore.RuntimeStatus do
  @moduledoc "Runtime status snapshots, revision hashes and acknowledged change streams."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Deployments
  alias MirrorNeuron.Persistence.RedisStore.Jobs
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Persistence.RedisStore.Schedules
  alias MirrorNeuron.Persistence.RedisStore.Values

  @runtime_status_event_max_count 10_000

  def persist_node_runtime_status(node_name, domain, snapshot) do
    script = """
    local state = {}
    local encoded = redis.call("get", KEYS[1])
    if encoded then state = cjson.decode(encoded) end
    local runtime_status = state["runtime_status"] or {}
    runtime_status[ARGV[2]] = cjson.decode(ARGV[3])
    state["runtime_status"] = runtime_status
    state["node"] = ARGV[1]
    state["updated_at"] = ARGV[4]
    local updated = cjson.encode(state)
    redis.call("set", KEYS[1], updated)
    redis.call("sadd", KEYS[2], ARGV[1])
    local event_id = redis.call(
      "xadd", KEYS[3], "MAXLEN", "~", ARGV[5], "*",
      "node", ARGV[1], "domain", ARGV[2], "revision", ARGV[6]
    )
    return {updated, event_id}
    """

    args = [
      "EVAL",
      script,
      "3",
      Keys.key("node", node_name, "state"),
      Keys.key("nodes"),
      runtime_status_stream_key(),
      node_name,
      domain,
      Jason.encode!(Values.stringify_map(snapshot)),
      Values.timestamp(),
      to_string(@runtime_status_event_max_count),
      to_string(Map.get(snapshot, "revision") || Map.get(snapshot, :revision) || "")
    ]

    with {:ok, [encoded, _event_id]} <- Connection.command(args),
         {:ok, state} when is_map(state) <- Jason.decode(encoded),
         :ok <- Connection.wait_for_replicas() do
      {:ok, state}
    else
      {:ok, _invalid} -> {:error, :invalid_node_state}
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  def read_node_runtime_status_events(node_name, count \\ 100) do
    stream_key = runtime_status_stream_key()
    group = runtime_status_consumer_group(node_name)
    consumer = to_string(node_name)

    with :ok <- ensure_runtime_status_group(stream_key, group),
         {:ok, pending} <-
           read_runtime_status_stream(stream_key, group, consumer, "0", count),
         {:ok, fresh} <-
           read_runtime_status_stream(
             stream_key,
             group,
             consumer,
             ">",
             max(count - length(pending), 0)
           ) do
      {:ok, pending ++ fresh}
    end
  end

  def ack_node_runtime_status_events(node_name, event_ids) when is_list(event_ids) do
    ack_runtime_status_stream_events(
      runtime_status_stream_key(),
      runtime_status_consumer_group(node_name),
      event_ids
    )
  end

  def runtime_status_snapshots(domains) when is_list(domains) do
    domains
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn domain, {:ok, snapshots} ->
      case runtime_status_records(domain) do
        {:ok, records} ->
          records = sort_runtime_status_records(domain, records)
          status = %{"count" => length(records), "records" => records}

          snapshot = %{
            "revision" => runtime_status_revision(status),
            "reported_at" => Values.timestamp(),
            "status" => status
          }

          {:cont, {:ok, Map.put(snapshots, domain, snapshot)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def read_node_cluster_runtime_status_events(node_name, count \\ 100) do
    stream_key = cluster_runtime_status_stream_key()
    group = cluster_runtime_status_consumer_group(node_name)
    consumer = to_string(node_name)

    with :ok <- ensure_runtime_status_group(stream_key, group),
         {:ok, pending} <-
           read_runtime_status_stream(stream_key, group, consumer, "0", count),
         {:ok, fresh} <-
           read_runtime_status_stream(
             stream_key,
             group,
             consumer,
             ">",
             max(count - length(pending), 0)
           ) do
      {:ok, pending ++ fresh}
    end
  end

  def ack_node_cluster_runtime_status_events(node_name, event_ids) when is_list(event_ids) do
    ack_runtime_status_stream_events(
      cluster_runtime_status_stream_key(),
      cluster_runtime_status_consumer_group(node_name),
      event_ids
    )
  end

  defp ack_runtime_status_stream_events(stream_key, group, event_ids) do
    event_ids =
      event_ids
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if event_ids == [] do
      {:ok, 0}
    else
      case Connection.command(["XACK", stream_key, group | event_ids]) do
        {:ok, count} when is_integer(count) ->
          with :ok <- Connection.wait_for_replicas(), do: {:ok, count}

        {:error, reason} ->
          {:error, Values.format_reason(reason)}

        other ->
          {:error, {:unexpected_runtime_status_ack_result, other}}
      end
    end
  end

  defp runtime_status_stream_key, do: Keys.key("runtime", "status", "events")

  def cluster_runtime_status_stream_key,
    do: Keys.key("runtime", "cluster", "status", "events")

  defp runtime_status_consumer_group(node_name),
    do: Keys.key("runtime", "status", "consumer", node_name)

  defp cluster_runtime_status_consumer_group(node_name),
    do: Keys.key("runtime", "cluster", "status", "consumer", node_name)

  def cluster_runtime_status_event_command(domain, entity_id, action, revision) do
    [
      "XADD",
      cluster_runtime_status_stream_key(),
      "MAXLEN",
      "~",
      to_string(@runtime_status_event_max_count),
      "*",
      "node",
      to_string(NodeAdapter.self()),
      "domain",
      domain,
      "entity_id",
      entity_id,
      "action",
      action,
      "revision",
      revision
    ]
  end

  defp runtime_status_records("jobs"), do: Jobs.list_job_summaries()

  defp runtime_status_records("schedules"), do: Schedules.list_schedules()

  defp runtime_status_records("deployments"), do: Deployments.list_deployments()

  defp runtime_status_records(domain), do: {:error, {:unsupported_runtime_status_domain, domain}}

  defp sort_runtime_status_records(domain, records) when is_list(records) do
    id_field =
      case domain do
        "jobs" -> "job_id"
        "schedules" -> "schedule_id"
        "deployments" -> "deployment_id"
      end

    Enum.sort_by(records, &(Map.get(&1, id_field) || ""))
  end

  def runtime_status_revision(value) do
    value
    |> canonical_runtime_status_value()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_runtime_status_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} ->
      {to_string(key), canonical_runtime_status_value(nested)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_runtime_status_value(value) when is_list(value),
    do: Enum.map(value, &canonical_runtime_status_value/1)

  defp canonical_runtime_status_value(value), do: value

  defp ensure_runtime_status_group(stream_key, group) do
    case Connection.command(["XGROUP", "CREATE", stream_key, group, "0", "MKSTREAM"]) do
      {:ok, "OK"} ->
        :ok

      {:error, %Redix.Error{message: message}} when is_binary(message) ->
        if String.contains?(message, "BUSYGROUP"), do: :ok, else: {:error, message}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}

      other ->
        {:error, {:unexpected_runtime_status_group_result, other}}
    end
  end

  defp read_runtime_status_stream(_stream_key, _group, _consumer, _id, count)
       when count <= 0,
       do: {:ok, []}

  defp read_runtime_status_stream(stream_key, group, consumer, id, count) do
    case Connection.command([
           "XREADGROUP",
           "GROUP",
           group,
           consumer,
           "COUNT",
           to_string(count),
           "STREAMS",
           stream_key,
           id
         ]) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, [[^stream_key, entries]]} ->
        {:ok,
         Enum.map(entries, fn [event_id, fields] ->
           fields = pairs_to_map(fields)

           %{
             "id" => event_id,
             "node" => fields["node"],
             "domain" => fields["domain"],
             "entity_id" => fields["entity_id"],
             "action" => fields["action"],
             "revision" => fields["revision"]
           }
         end)}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}

      other ->
        {:error, {:unexpected_runtime_status_read_result, other}}
    end
  end

  defp pairs_to_map(values) when is_list(values) do
    values
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, value] -> {key, value} end)
  end
end
