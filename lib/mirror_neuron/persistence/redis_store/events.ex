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

    redis.call("rpush", KEYS[2], ARGV[1])

    local max_count = tonumber(ARGV[2]) or 0
    if max_count > 0 then
      redis.call("ltrim", KEYS[2], -max_count, -1)
    end

    local ttl_seconds = tonumber(ARGV[3]) or 0
    if ttl_seconds > 0 then
      redis.call("expire", KEYS[2], ttl_seconds)
    end

    redis.call("publish", ARGV[4], ARGV[1])
    return 1
    """

    with {:ok, encoded} <- Jason.encode(event),
         {:ok, result} <-
           Connection.command([
             "EVAL",
             script,
             "2",
             cancellation_key,
             event_key,
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

    redis.call("rpush", KEYS[2], ARGV[1])

    local max_count = tonumber(ARGV[2]) or 0
    if max_count > 0 then
      redis.call("ltrim", KEYS[2], -max_count, -1)
    end

    local ttl_seconds = tonumber(ARGV[3]) or 0
    if ttl_seconds > 0 then
      redis.call("expire", KEYS[2], ttl_seconds)
    end

    redis.call("publish", ARGV[4], ARGV[1])
    return 1
    """

    with {:ok, encoded} <- Jason.encode(event),
         {:ok, result} <-
           Connection.command([
             "EVAL",
             script,
             "2",
             Keys.key("job", job_id),
             Keys.key("job", job_id, "events"),
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
    encoded_events = Enum.map(events, &Jason.encode!/1)

    commands =
      [["DEL", event_key]] ++
        Enum.map(encoded_events, fn encoded -> ["RPUSH", event_key, encoded] end) ++
        event_retention_commands(event_key)

    with {:ok, _results} <- Connection.transaction(commands),
         :ok <- Connection.wait_for_replicas() do
      {:ok, events}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
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
