defmodule MirrorNeuron.Persistence.RedisStore.Events do
  @moduledoc "Persists bounded event logs and publishes committed events."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.Values

  def append_event(job_id, event) do
    cancellation_key = Keys.key("job", job_id, "cancellation")
    event_key = Keys.key("job", job_id, "events")

    script = """
    local encoded_cancellation = redis.call("get", KEYS[1])
    if encoded_cancellation then
      local cancellation = cjson.decode(encoded_cancellation)
      if cancellation["public_cleared_at"] then
        return 0
      end
    end

    redis.call("setnx", KEYS[3], redis.call("llen", KEYS[2]))
    redis.call("incr", KEYS[3])
    redis.call("rpush", KEYS[2], ARGV[1])

    local max_count = tonumber(ARGV[2]) or 0
    if max_count > 0 then
      redis.call("ltrim", KEYS[2], -max_count, -1)
    end

    local ttl_seconds = tonumber(ARGV[3]) or 0
    if ttl_seconds > 0 then
      redis.call("expire", KEYS[2], ttl_seconds)
      redis.call("expire", KEYS[3], ttl_seconds)
    end

    redis.call("publish", ARGV[4], ARGV[1])
    return 1
    """

    with {:ok, encoded} <- Jason.encode(event),
         {:ok, result} <-
           Connection.command([
             "EVAL",
             script,
             "3",
             cancellation_key,
             event_key,
             Keys.key("job", job_id, "event_cursor"),
             encoded,
             to_string(RetentionPolicy.event_max_count()),
             to_string(RetentionPolicy.event_ttl_seconds()),
             Keys.channel("events", job_id)
           ]),
         :ok <- Connection.wait_for_replicas() do
      case result do
        1 -> {:ok, event}
        0 -> {:ok, :job_cleared}
        other -> {:error, Values.format_reason(other)}
      end
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  @doc false
  def append_event_if_job_exists(job_id, event) do
    script = """
    if redis.call("exists", KEYS[1]) == 0 then
      return 0
    end

    redis.call("setnx", KEYS[3], redis.call("llen", KEYS[2]))
    redis.call("incr", KEYS[3])
    redis.call("rpush", KEYS[2], ARGV[1])

    local max_count = tonumber(ARGV[2]) or 0
    if max_count > 0 then
      redis.call("ltrim", KEYS[2], -max_count, -1)
    end

    local ttl_seconds = tonumber(ARGV[3]) or 0
    if ttl_seconds > 0 then
      redis.call("expire", KEYS[2], ttl_seconds)
      redis.call("expire", KEYS[3], ttl_seconds)
    end

    redis.call("publish", ARGV[4], ARGV[1])
    return 1
    """

    with {:ok, encoded} <- Jason.encode(event),
         {:ok, result} <-
           Connection.command([
             "EVAL",
             script,
             "3",
             Keys.key("job", job_id),
             Keys.key("job", job_id, "events"),
             Keys.key("job", job_id, "event_cursor"),
             encoded,
             to_string(RetentionPolicy.event_max_count()),
             to_string(RetentionPolicy.event_ttl_seconds()),
             Keys.channel("events", job_id)
           ]),
         :ok <- Connection.wait_for_replicas() do
      case result do
        1 -> {:ok, event}
        0 -> {:ok, :job_missing}
        other -> {:error, Values.format_reason(other)}
      end
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  def read_events(job_id, start \\ "0", stop \\ "-1") do
    case Connection.command([
           "LRANGE",
           Keys.key("job", job_id, "events"),
           to_string(start),
           to_string(stop)
         ]) do
      {:ok, items} -> {:ok, Enum.map(items, &Jason.decode!/1)}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def replace_job_events(job_id, events) when is_list(events) do
    event_key = Keys.key("job", job_id, "events")
    cursor_key = Keys.key("job", job_id, "event_cursor")
    encoded_events = Enum.map(events, &Jason.encode!/1)

    commands =
      [["DEL", event_key], ["SET", cursor_key, to_string(length(events))]] ++
        Enum.map(encoded_events, fn encoded -> ["RPUSH", event_key, encoded] end) ++
        event_retention_commands(event_key) ++
        RetentionPolicy.maybe_expire_key_command(cursor_key, RetentionPolicy.event_ttl_seconds())

    with {:ok, _results} <- Connection.transaction(commands),
         :ok <- Connection.wait_for_replicas() do
      {:ok, events}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  # Read the retained range and high-water mark atomically. A list written by
  # an older Core is numbered from one on first read or append.
  def activity_page(job_id, cursor, limit) when cursor >= 0 and limit in 0..500 do
    script = """
    local size = redis.call("llen", KEYS[1])
    local last = tonumber(redis.call("get", KEYS[2])) or size
    local base = last - size
    local cursor = tonumber(ARGV[1])
    local limit = tonumber(ARGV[2])
    if cursor > last or (cursor > 0 and cursor < base) then return {-1, last, {}} end
    local start = math.max(0, cursor - base)
    if limit == 0 then limit = 50; start = math.max(start, size - limit) end
    return {base + start, last, redis.call("lrange", KEYS[1], start, start + limit - 1)}
    """

    case Connection.command([
           "EVAL",
           script,
           "2",
           Keys.key("job", job_id, "events"),
           Keys.key("job", job_id, "event_cursor"),
           to_string(cursor),
           to_string(limit)
         ]) do
      {:ok, [-1, _, _]} ->
        {:error, :activity_replay_gap}

      {:ok, [base, last, rows]} ->
        {:ok,
         rows
         |> Enum.with_index(base + 1)
         |> Enum.map(fn {row, sequence} ->
           row |> Jason.decode!() |> Map.merge(%{"sequence" => sequence, "_journal_head" => last})
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp event_retention_commands(event_key) do
    maybe_trim_event_log_command(event_key) ++
      RetentionPolicy.maybe_expire_key_command(event_key, RetentionPolicy.event_ttl_seconds())
  end

  defp maybe_trim_event_log_command(event_key) do
    case RetentionPolicy.event_max_count() do
      max_count when is_integer(max_count) and max_count > 0 ->
        [["LTRIM", event_key, "-#{max_count}", "-1"]]

      _ ->
        []
    end
  end
end
