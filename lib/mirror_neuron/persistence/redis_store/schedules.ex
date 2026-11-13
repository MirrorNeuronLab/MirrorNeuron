defmodule MirrorNeuron.Persistence.RedisStore.Schedules do
  @moduledoc "Fenced schedule records, occurrence receipts and trigger events."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Leases
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.RuntimeStatus
  alias MirrorNeuron.Persistence.RedisStore.ScheduleIndex
  alias MirrorNeuron.Persistence.RedisStore.Values

  @schedules_set "schedules"
  @schedule_due_zset "schedule:due"
  @trigger_events_list "trigger:events"
  @runtime_status_event_max_count 10_000

  def reserve_schedule_occurrence(schedule_id, token, record, lock) do
    script = """
    if redis.call("get", KEYS[1]) ~= ARGV[1] or redis.call("exists", KEYS[2]) == 0 then
      return {0, ""}
    end
    local existing = redis.call("hget", KEYS[3], ARGV[2])
    if existing then return {2, existing} end
    redis.call("hset", KEYS[3], ARGV[2], ARGV[3])
    return {1, ARGV[3]}
    """

    with {:ok, [state, contents]} <-
           Connection.command([
             "EVAL",
             script,
             "3",
             Keys.key("lease", lock.lease_name),
             Keys.key("schedule", schedule_id),
             Keys.key("schedule-occurrences", schedule_id),
             Leases.fenced_lease_value(lock.owner, lock.lease["epoch"]),
             token,
             Jason.encode!(record)
           ]) do
      case state do
        0 ->
          {:error, :not_owner}

        value when value in [1, 2] ->
          with :ok <- Connection.wait_for_replicas(), {:ok, saved} <- Jason.decode(contents) do
            {:ok, if(value == 1, do: :new, else: :existing), saved}
          end
      end
    end
  end

  def complete_schedule_occurrence(schedule_id, token, record, lock) do
    script = """
    if redis.call("get", KEYS[1]) ~= ARGV[1] or redis.call("exists", KEYS[2]) == 0 then
      return 0
    end
    local existing = redis.call("hget", KEYS[3], ARGV[2])
    if not existing or cjson.decode(existing).run_id ~= cjson.decode(ARGV[3]).run_id then
      return 0
    end
    redis.call("hset", KEYS[3], ARGV[2], ARGV[3])
    return 1
    """

    case Connection.command([
           "EVAL",
           script,
           "3",
           Keys.key("lease", lock.lease_name),
           Keys.key("schedule", schedule_id),
           Keys.key("schedule-occurrences", schedule_id),
           Leases.fenced_lease_value(lock.owner, lock.lease["epoch"]),
           token,
           Jason.encode!(record)
         ]) do
      {:ok, 1} -> Connection.wait_for_replicas()
      {:ok, 0} -> {:error, :not_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  def persist_schedule(schedule_id, schedule_map) do
    schedule = prepare_schedule(schedule_id, schedule_map)
    commands = schedule_commands(schedule_id, schedule)

    with {:ok, results} <- Connection.transaction(commands),
         :ok <- Results.expect_first_result(results, fn value -> value == "OK" end),
         :ok <- Results.expect_no_redis_errors(results),
         :ok <- Connection.wait_for_replicas() do
      {:ok, schedule}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def schedule_commands(schedule_id, schedule) do
    revision = RuntimeStatus.runtime_status_revision(schedule)

    [
      ["SET", Keys.key("schedule", schedule_id), Jason.encode!(schedule)],
      ["SADD", Keys.key(@schedules_set), schedule_id],
      ["ZREM", Keys.key(@schedule_due_zset), schedule_id]
    ] ++
      schedule_due_commands(schedule) ++
      [
        RuntimeStatus.cluster_runtime_status_event_command(
          "schedules",
          schedule_id,
          "upsert",
          revision
        )
      ]
  end

  def persist_schedule_fenced(schedule_id, schedule_map, lease_name, owner_id, epoch) do
    schedule = prepare_schedule(schedule_id, schedule_map)
    due_score = schedule_due_score(schedule)
    revision = RuntimeStatus.runtime_status_revision(schedule)

    script = """
    if redis.call("get", KEYS[1]) ~= ARGV[1] then
      return 0
    end

    redis.call("set", KEYS[2], ARGV[2])
    redis.call("sadd", KEYS[3], ARGV[3])
    redis.call("zrem", KEYS[4], ARGV[3])

    if ARGV[4] ~= "" then
      redis.call("zadd", KEYS[4], ARGV[4], ARGV[3])
    end

    redis.call(
      "xadd", KEYS[5], "MAXLEN", "~", ARGV[7], "*",
      "node", ARGV[5], "domain", "schedules", "entity_id", ARGV[3],
      "action", "upsert", "revision", ARGV[6]
    )

    return 1
    """

    args = [
      "EVAL",
      script,
      "5",
      Keys.key("lease", lease_name),
      Keys.key("schedule", schedule_id),
      Keys.key(@schedules_set),
      Keys.key(@schedule_due_zset),
      RuntimeStatus.cluster_runtime_status_stream_key(),
      Leases.fenced_lease_value(owner_id, epoch),
      Jason.encode!(schedule),
      schedule_id,
      due_score,
      to_string(NodeAdapter.self()),
      revision,
      to_string(@runtime_status_event_max_count)
    ]

    case Connection.command(args) do
      {:ok, 1} ->
        with :ok <- Connection.wait_for_replicas(), do: {:ok, schedule}

      {:ok, 0} ->
        {:error, :not_owner}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def fetch_schedule(schedule_id) do
    case Connection.command(["GET", Keys.key("schedule", schedule_id)]) do
      {:ok, nil} ->
        {:error, "schedule #{schedule_id} was not found"}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, schedule} when is_map(schedule) -> {:ok, schedule}
          {:ok, _invalid} -> {:error, :invalid_schedule}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def list_schedules do
    with {:ok, schedule_ids} <- Connection.command(["SMEMBERS", Keys.key(@schedules_set)]) do
      fetch_indexed_schedules(schedule_ids)
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def list_due_schedules(now_iso) do
    score = schedule_score(now_iso)

    with {:ok, schedule_ids} <-
           Connection.command([
             "ZRANGEBYSCORE",
             Keys.key(@schedule_due_zset),
             "-inf",
             to_string(score)
           ]) do
      fetch_indexed_schedules(schedule_ids)
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def delete_schedule(schedule_id) do
    with {:ok, results} <- Connection.transaction(delete_schedule_commands(schedule_id)),
         :ok <- Results.expect_no_redis_errors(results),
         :ok <- delete_schedule_lease_metadata(schedule_id),
         :ok <- Connection.wait_for_replicas() do
      :ok
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def delete_schedule_commands(schedule_id) do
    revision =
      RuntimeStatus.runtime_status_revision(%{
        "deleted" => schedule_id,
        "at" => Values.timestamp()
      })

    [
      ["DEL", Keys.key("schedule", schedule_id), Keys.key("schedule-occurrences", schedule_id)],
      ["SREM", Keys.key(@schedules_set), schedule_id],
      ["ZREM", Keys.key(@schedule_due_zset), schedule_id],
      RuntimeStatus.cluster_runtime_status_event_command(
        "schedules",
        schedule_id,
        "delete",
        revision
      )
    ]
  end

  def delete_schedule_fenced(schedule_id, lease_name, owner_id, epoch) do
    revision =
      RuntimeStatus.runtime_status_revision(%{
        "deleted" => schedule_id,
        "at" => Values.timestamp()
      })

    script = """
    if redis.call("get", KEYS[1]) ~= ARGV[1] then
      return 0
    end

    redis.call("del", KEYS[2], KEYS[7])
    redis.call("srem", KEYS[3], ARGV[2])
    redis.call("zrem", KEYS[4], ARGV[2])
    redis.call("del", KEYS[1])
    redis.call("del", KEYS[5])
    redis.call(
      "xadd", KEYS[6], "MAXLEN", "~", ARGV[5], "*",
      "node", ARGV[3], "domain", "schedules", "entity_id", ARGV[2],
      "action", "delete", "revision", ARGV[4]
    )
    return 1
    """

    case Connection.command([
           "EVAL",
           script,
           "7",
           Keys.key("lease", lease_name),
           Keys.key("schedule", schedule_id),
           Keys.key(@schedules_set),
           Keys.key(@schedule_due_zset),
           Keys.key("lease", lease_name, "epoch"),
           RuntimeStatus.cluster_runtime_status_stream_key(),
           Keys.key("schedule-occurrences", schedule_id),
           Leases.fenced_lease_value(owner_id, epoch),
           schedule_id,
           to_string(NodeAdapter.self()),
           revision,
           to_string(@runtime_status_event_max_count)
         ]) do
      {:ok, 1} ->
        with :ok <- delete_schedule_lease_metadata(schedule_id),
             do: Connection.wait_for_replicas()

      {:ok, 0} ->
        {:error, :not_owner}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def append_trigger_event(event_id, event_map) do
    event =
      event_map
      |> Values.stringify_map()
      |> Map.put("event_id", event_id)
      |> Map.put_new("created_at", Values.timestamp())

    encoded = Jason.encode!(event)

    with {:ok, _results} <-
           Connection.transaction([
             ["LPUSH", Keys.key(@trigger_events_list), encoded],
             ["LTRIM", Keys.key(@trigger_events_list), "0", "999"]
           ]),
         :ok <- Connection.wait_for_replicas() do
      {:ok, event}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def list_trigger_events(limit \\ 100) do
    stop = max(limit, 1) - 1

    case Connection.command(["LRANGE", Keys.key(@trigger_events_list), "0", to_string(stop)]) do
      {:ok, items} -> {:ok, Values.decode_json_items(items)}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp fetch_indexed_schedules(schedule_ids) do
    schedule_ids
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn schedule_id, {:ok, schedules} ->
      case fetch_schedule(schedule_id) do
        {:ok, schedule} ->
          {:cont, {:ok, [schedule | schedules]}}

        {:error, reason} ->
          cond do
            missing_schedule?(schedule_id, reason) ->
              case ScheduleIndex.purge_missing_schedule(schedule_id) do
                {:ok, _result} -> {:cont, {:ok, schedules}}
                {:error, cleanup_reason} -> {:halt, {:error, cleanup_reason}}
              end

            corrupt_schedule?(reason) ->
              Logger.debug("ignoring unreadable schedule #{schedule_id}: #{inspect(reason)}")
              {:cont, {:ok, schedules}}

            true ->
              {:halt, {:error, Values.format_reason(reason)}}
          end
      end
    end)
    |> case do
      {:ok, schedules} -> {:ok, Enum.reverse(schedules)}
      {:error, _reason} = error -> error
    end
  end

  defp schedule_due_commands(
         %{"enabled" => true, "status" => status, "next_run_at" => next_run_at} = schedule
       )
       when status in ["active", "running"] and is_binary(next_run_at) do
    [
      [
        "ZADD",
        Keys.key(@schedule_due_zset),
        to_string(schedule_score(next_run_at)),
        schedule["schedule_id"]
      ]
    ]
  end

  defp schedule_due_commands(_schedule), do: []

  defp schedule_due_score(%{"enabled" => true, "status" => status, "next_run_at" => next_run_at})
       when status in ["active", "running"] and is_binary(next_run_at),
       do: to_string(schedule_score(next_run_at))

  defp schedule_due_score(_schedule), do: ""

  defp delete_schedule_lease_metadata(schedule_id) do
    case Connection.scan_keys(Keys.key("lease", "schedule:#{schedule_id}:*")) do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        case Connection.command(["DEL" | keys]) do
          {:ok, _deleted} -> :ok
          {:error, reason} -> {:error, Values.format_reason(reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def prepare_schedule(schedule_id, schedule_map) do
    schedule_map
    |> Values.stringify_map()
    |> Map.put("schedule_id", schedule_id)
    |> Map.update("revision", 1, &(&1 + 1))
    |> Map.put_new("created_at", Values.timestamp())
    |> Map.put("updated_at", Values.timestamp())
  end

  defp schedule_score(iso_datetime) when is_binary(iso_datetime) do
    case DateTime.from_iso8601(iso_datetime) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> 0
    end
  end

  defp schedule_score(_value), do: 0

  defp missing_schedule?(schedule_id, reason),
    do: reason == "schedule #{schedule_id} was not found"

  defp corrupt_schedule?(:invalid_schedule), do: true

  defp corrupt_schedule?(reason), do: Values.corrupt_json?(reason)
end
