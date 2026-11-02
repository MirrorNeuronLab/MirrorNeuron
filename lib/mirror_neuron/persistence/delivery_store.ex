defmodule MirrorNeuron.Persistence.DeliveryStore do
  @moduledoc "Atomic durable delivery storage; RedisStore retains the public facade."
  alias MirrorNeuron.Persistence.RedisStore
  @delivery_consumer_group "mirror_neuron_agents"
  @ownership_check """
  local function owns_receipt(receipt, stream, group, consumer)
    if redis.call('hget', receipt, 'consumer') ~= consumer then return false end
    local id = redis.call('hget', receipt, 'stream_id')
    if not id then return false end
    local pending = redis.call('xpending', stream, group, id, id, 1)
    return #pending > 0 and pending[1][2] == consumer
  end
  """
  @doc false
  def enqueue_delivery(job_id, agent_id, message, opts) do
    message_id = MirrorNeuron.Message.id(message)
    encoded = Jason.encode!(message)
    digest = delivery_identity_digest(message)
    now_ms = Keyword.fetch!(opts, :now_ms)
    deadline_ms = Keyword.fetch!(opts, :deadline_ms)
    pending_ttl_seconds = Keyword.fetch!(opts, :pending_ttl_seconds)
    stream_ttl_seconds = Keyword.fetch!(opts, :stream_ttl_seconds)
    max_pending_agent = Keyword.fetch!(opts, :max_pending_agent)
    max_pending_job = Keyword.fetch!(opts, :max_pending_job)

    receipt_key = delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = delivery_stream_key(job_id, agent_id)
    agent_count_key = delivery_agent_count_key(job_id, agent_id)
    job_count_key = delivery_job_count_key(job_id, agent_id)
    index_key = delivery_index_key(job_id)

    script = """
    local function accept_command()
      if KEYS[6] ~= '' then
        local encoded = redis.call('get', KEYS[6])
        if encoded then
          local record = cjson.decode(encoded)
          if record.status == 'pending_admission' or record.status == 'not_accepted' then
            record.accepted = true
            record.status = 'accepted'
            record.revision = (record.revision or 0) + 1
            record.updated_at = ARGV[10]
            redis.call('set', KEYS[6], cjson.encode(record), 'KEEPTTL')
          end
        end
      end
    end
    if redis.call("exists", KEYS[1]) == 1 then
      local existing_digest = redis.call("hget", KEYS[1], "digest")
      local status = redis.call("hget", KEYS[1], "status") or "unknown"
      local stream_id = redis.call("hget", KEYS[1], "stream_id") or ""
      if existing_digest ~= ARGV[2] then
        return {"conflict", status, stream_id}
      end
      accept_command()
      return {"duplicate", status, stream_id}
    end

    local agent_count = tonumber(redis.call("get", KEYS[3]) or "0")
    local job_count = tonumber(redis.call("get", KEYS[4]) or "0")
    if agent_count >= tonumber(ARGV[8]) then
      return {"agent_full", tostring(agent_count), ""}
    end
    if job_count >= tonumber(ARGV[9]) then
      return {"job_full", tostring(job_count), ""}
    end

    local stream_id = redis.call(
      "xadd", KEYS[2], "*", "message_id", ARGV[1], "payload", ARGV[3]
    )
    redis.call(
      "hset", KEYS[1],
      "message_id", ARGV[1],
      "digest", ARGV[2],
      "status", "queued",
      "stream_id", stream_id,
      "attempts", "0",
      "deadline_ms", ARGV[5],
      "enqueued_at_ms", ARGV[4]
    )
    redis.call("expire", KEYS[1], ARGV[6])
    redis.call("expire", KEYS[2], ARGV[7])
    redis.call("incr", KEYS[3])
    redis.call("expire", KEYS[3], ARGV[7])
    redis.call("incr", KEYS[4])
    redis.call("expire", KEYS[4], ARGV[7])
    redis.call("sadd", KEYS[5], KEYS[1], KEYS[2], KEYS[3], KEYS[4])
    redis.call("expire", KEYS[5], ARGV[7])
    accept_command()
    return {"queued", "queued", stream_id}
    """

    args = [
      "EVAL",
      script,
      "6",
      receipt_key,
      stream_key,
      agent_count_key,
      job_count_key,
      index_key,
      Keyword.get(opts, :command_receipt_key, ""),
      message_id,
      digest,
      encoded,
      to_string(now_ms),
      to_string(deadline_ms),
      to_string(pending_ttl_seconds),
      to_string(stream_ttl_seconds),
      to_string(max_pending_agent),
      to_string(max_pending_job),
      MirrorNeuron.Runtime.timestamp()
    ]

    case command(args) do
      {:ok, ["queued", _status, stream_id]} ->
        with :ok <- wait_for_replicas(agent_id),
             do: {:ok, %{status: :queued, stream_id: stream_id, message_id: message_id}}

      {:ok, ["duplicate", status, stream_id]} ->
        with :ok <- wait_for_replicas(agent_id),
             do:
               {:ok,
                %{
                  status: :duplicate,
                  delivery_status: status,
                  stream_id: stream_id,
                  message_id: message_id
                }}

      {:ok, ["conflict", status, _stream_id]} ->
        {:error, {:message_id_conflict, message_id, status}}

      {:ok, ["agent_full", count, _stream_id]} ->
        {:error, {:delivery_backpressure, :agent, parse_redis_integer(count)}}

      {:ok, ["job_full", count, _stream_id]} ->
        {:error, {:delivery_backpressure, :job, parse_redis_integer(count)}}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, {:unexpected_delivery_enqueue_result, other}}
    end
  end

  defp delivery_identity_digest(message) do
    message
    |> update_in(["envelope"], fn
      envelope when is_map(envelope) -> Map.drop(envelope, ["attempt", "timestamp"])
      envelope -> envelope
    end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def read_deliveries(job_id, agent_id, consumer, opts) do
    stream_key = delivery_stream_key(job_id, agent_id)
    lease_ms = Keyword.fetch!(opts, :lease_ms)
    max_attempts = Keyword.fetch!(opts, :max_attempts)
    now_ms = Keyword.fetch!(opts, :now_ms)
    count = Keyword.get(opts, :count, 1)

    with :ok <-
           maybe_ensure_delivery_group(
             stream_key,
             Keyword.fetch!(opts, :stream_ttl_seconds),
             Keyword.get(opts, :ensure_group, true)
           ),
         {:ok, entries} <- delivery_entries(stream_key, consumer, lease_ms, count, opts) do
      entries
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case prepare_delivery(job_id, agent_id, consumer, entry, now_ms, max_attempts) do
          {:ok, delivery} -> {:cont, {:ok, [delivery | acc]}}
          {:discard, discard} -> {:cont, {:ok, [discard | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, deliveries} -> {:ok, Enum.reverse(deliveries)}
        error -> error
      end
    end
  end

  defp delivery_entries(stream_key, consumer, lease_ms, count, opts) do
    if Keyword.get(opts, :strict_fifo, false) do
      # Select only the oldest pending delivery. A deferred head must not be
      # bypassed by new work in the same lane. Selection/claim is atomic.
      script = """
      local pending = redis.call("xpending", KEYS[1], ARGV[1], "-", "+", 1)
      if #pending > 0 then
        if pending[1][3] < tonumber(ARGV[3]) then return {} end
        return redis.call("xclaim", KEYS[1], ARGV[1], ARGV[2], ARGV[3], pending[1][1])
      end
      local fresh = redis.call("xreadgroup", "GROUP", ARGV[1], ARGV[2], "COUNT", 1, "STREAMS", KEYS[1], ">")
      if not fresh then return {} end
      return fresh[1][2]
      """

      case command([
             "EVAL",
             script,
             "1",
             stream_key,
             @delivery_consumer_group,
             consumer,
             to_string(lease_ms)
           ]) do
        {:ok, entries} -> {:ok, parse_delivery_entries(entries)}
        error -> error
      end
    else
      with {:ok, claimed} <-
             maybe_claim_stale_deliveries(
               stream_key,
               consumer,
               lease_ms,
               count,
               Keyword.get(opts, :claim_stale, true)
             ),
           {:ok, entries} <- read_new_deliveries(stream_key, consumer, count - length(claimed)) do
        {:ok, claimed ++ entries}
      end
    end
  end

  @doc false
  def ack_delivery(job_id, agent_id, consumer, stream_id, message_id, ack_ttl_seconds) do
    receipt_key = delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = delivery_stream_key(job_id, agent_id)

    script = """
    local status = redis.call("hget", KEYS[1], "status")
    local pending = redis.call('xpending', KEYS[2], ARGV[3], ARGV[4], ARGV[4], 1)
    if #pending > 0 and pending[1][2] ~= ARGV[1] then return 0 end
    if status and status ~= "acked" and redis.call("hget", KEYS[1], "consumer") ~= ARGV[1] then return 0 end
    if status ~= "acked" and status ~= "dead_letter" then
      redis.call("hset", KEYS[1], "status", "acked", "consumer", ARGV[1])
      local agent_count = tonumber(redis.call("get", KEYS[3]) or "0")
      local job_count = tonumber(redis.call("get", KEYS[4]) or "0")
      if agent_count > 0 then redis.call("decr", KEYS[3]) end
      if job_count > 0 then redis.call("decr", KEYS[4]) end
    end
    if redis.call("exists", KEYS[1]) == 1 then redis.call("expire", KEYS[1], ARGV[2]) end
    redis.call("srem", KEYS[5], KEYS[1])
    redis.call("xack", KEYS[2], ARGV[3], ARGV[4])
    redis.call("xdel", KEYS[2], ARGV[4])
    return 1
    """

    args = [
      "EVAL",
      script,
      "5",
      receipt_key,
      stream_key,
      delivery_agent_count_key(job_id, agent_id),
      delivery_job_count_key(job_id, agent_id),
      delivery_index_key(job_id),
      consumer,
      to_string(ack_ttl_seconds),
      @delivery_consumer_group,
      stream_id
    ]

    case command(args) do
      {:ok, 1} -> wait_for_replicas(agent_id)
      {:ok, 0} -> {:error, :delivery_owner_changed}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_ack_result, other}}
    end
  end

  @doc false
  def dead_letter_delivery(job_id, agent_id, stream_id, message_id, reason, ttl_seconds) do
    receipt_key = delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = delivery_stream_key(job_id, agent_id)

    script = """
    local status = redis.call("hget", KEYS[1], "status")
    if status ~= "acked" and status ~= "dead_letter" then
      local agent_count = tonumber(redis.call("get", KEYS[3]) or "0")
      local job_count = tonumber(redis.call("get", KEYS[4]) or "0")
      if agent_count > 0 then redis.call("decr", KEYS[3]) end
      if job_count > 0 then redis.call("decr", KEYS[4]) end
    end
    if redis.call("exists", KEYS[1]) == 1 then
      redis.call("hset", KEYS[1], "status", "dead_letter", "reason", ARGV[1])
      redis.call("expire", KEYS[1], ARGV[2])
    end
    redis.call("srem", KEYS[5], KEYS[1])
    redis.call("xack", KEYS[2], ARGV[3], ARGV[4])
    redis.call("xdel", KEYS[2], ARGV[4])
    return 1
    """

    args = [
      "EVAL",
      script,
      "5",
      receipt_key,
      stream_key,
      delivery_agent_count_key(job_id, agent_id),
      delivery_job_count_key(job_id, agent_id),
      delivery_index_key(job_id),
      inspect(reason),
      to_string(ttl_seconds),
      @delivery_consumer_group,
      stream_id
    ]

    case command(args) do
      {:ok, 1} -> wait_for_replicas(agent_id)
      {:error, command_reason} -> {:error, format_reason(command_reason)}
      other -> {:error, {:unexpected_delivery_dead_letter_result, other}}
    end
  end

  @doc false
  def renew_delivery(job_id, agent_id, consumer, stream_id),
    do: move_owned_pending(job_id, agent_id, consumer, stream_id, 0)

  @doc false
  def retry_delivery(job_id, agent_id, consumer, stream_id, delay_ms, lease_ms),
    do: move_owned_pending(job_id, agent_id, consumer, stream_id, max(lease_ms - delay_ms, 0))

  defp move_owned_pending(job_id, agent_id, consumer, stream_id, idle_ms) do
    script = """
    local pending = redis.call('xpending', KEYS[1], ARGV[1], ARGV[3], ARGV[3], 1)
    if #pending == 0 then return {'missing'} end
    if pending[1][2] ~= ARGV[2] then return {'owner_changed'} end
    return redis.call('xclaim', KEYS[1], ARGV[1], ARGV[2], 0, ARGV[3], 'IDLE', ARGV[4], 'JUSTID')
    """

    case command([
           "EVAL",
           script,
           "1",
           delivery_stream_key(job_id, agent_id),
           @delivery_consumer_group,
           consumer,
           stream_id,
           to_string(idle_ms)
         ]) do
      {:ok, [^stream_id]} -> :ok
      {:ok, ["missing"]} -> {:error, :delivery_not_pending}
      {:ok, ["owner_changed"]} -> {:error, :delivery_owner_changed}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_renew_result, other}}
    end
  end

  def defer_delivery(job_id, agent_id, consumer, delivery) do
    script =
      @ownership_check <>
        """
        if not owns_receipt(KEYS[1], KEYS[2], ARGV[2], ARGV[1]) then return 0 end
        if redis.call('hget', KEYS[1], 'status') == 'processing' then
          local n = tonumber(redis.call('hget', KEYS[1], 'attempts') or '0')
          redis.call('hset', KEYS[1], 'attempts', math.max(n - 1, 0), 'status', 'deferred')
        end
        return 1
        """

    case command([
           "EVAL",
           script,
           "2",
           delivery_receipt_key(job_id, agent_id, delivery.message_id),
           delivery_stream_key(job_id, agent_id),
           consumer,
           @delivery_consumer_group
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :delivery_owner_changed}
      error -> error
    end
  end

  @doc false
  def fetch_delivery_receipt(job_id, agent_id, message_id) do
    case command(["HGETALL", delivery_receipt_key(job_id, agent_id, message_id)]) do
      {:ok, []} -> {:error, :not_found}
      {:ok, values} -> {:ok, values |> pairs_to_map() |> parse_delivery_receipt()}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  def read_outbox(job_id, agent_id, message_id) do
    command(["HGET", delivery_receipt_key(job_id, agent_id, message_id), "outbox"])
  end

  def begin_invocation(job_id, agent_id, message_id, consumer) do
    script =
      @ownership_check <>
        """
        if not owns_receipt(KEYS[1], KEYS[2], ARGV[2], ARGV[1]) then return 'owner_changed' end
        local phase = redis.call('hget', KEYS[1], 'invocation')
        if phase then return phase end
        redis.call('hset', KEYS[1], 'invocation', 'executing')
        return 'started'
        """

    with {:ok, phase} <-
           command([
             "EVAL",
             script,
             "2",
             delivery_receipt_key(job_id, agent_id, message_id),
             delivery_stream_key(job_id, agent_id),
             consumer,
             @delivery_consumer_group
           ]),
         :ok <- wait_for_replicas(agent_id),
         do: {:ok, phase}
  end

  def abandon_invocation(job_id, agent_id, message_id, consumer) do
    script =
      @ownership_check <>
        """
        if not owns_receipt(KEYS[1], KEYS[2], ARGV[2], ARGV[1]) then return 0 end
        redis.call('hdel', KEYS[1], 'invocation')
        return 1
        """

    command([
      "EVAL",
      script,
      "2",
      delivery_receipt_key(job_id, agent_id, message_id),
      delivery_stream_key(job_id, agent_id),
      consumer,
      @delivery_consumer_group
    ])
  end

  def read_checkpoint(job_id, agent_id, epoch) do
    command(["GET", checkpoint_key(job_id, agent_id, epoch)])
  end

  def write_outbox(
        job_id,
        agent_id,
        message_id,
        encoded,
        consumer,
        logical_agent,
        epoch,
        checkpoint
      ) do
    script =
      @ownership_check <>
        """
        if not owns_receipt(KEYS[1], KEYS[4], ARGV[4], ARGV[2]) then return 0 end
        local previous = redis.call('hget', KEYS[1], 'outbox')
        if previous and previous ~= ARGV[1] then return -1 end
        redis.call('hset', KEYS[1], 'outbox', ARGV[1], 'invocation', 'completed')
        if not previous then redis.call('set', KEYS[2], ARGV[3], 'EX', 604800) end
        redis.call('sadd', KEYS[3], KEYS[2])
        return 1
        """

    case command([
           "EVAL",
           script,
           "4",
           delivery_receipt_key(job_id, agent_id, message_id),
           checkpoint_key(job_id, logical_agent, epoch),
           delivery_index_key(job_id),
           delivery_stream_key(job_id, agent_id),
           encoded,
           consumer,
           checkpoint,
           @delivery_consumer_group
         ]) do
      {:ok, 1} -> wait_for_replicas(agent_id)
      {:ok, _} -> {:error, :outbox_conflict}
      error -> error
    end
  end

  defp checkpoint_key(job_id, agent_id, epoch),
    do: key("job", job_id, "checkpoint", agent_id, to_string(epoch || 0))

  @doc false
  def delivery_pending_count(job_id, agent_id) do
    case command(["GET", delivery_agent_count_key(job_id, agent_id)]) do
      {:ok, nil} -> {:ok, 0}
      {:ok, count} -> {:ok, parse_redis_integer(count)}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  @doc false
  def expire_job_deliveries(job_id, ttl_seconds) do
    index_key = delivery_index_key(job_id)

    with {:ok, keys} <- command(["SMEMBERS", index_key]),
         # Protected projections and checkpoints retain their own replay TTL.
         keys <- Enum.reject(keys, &protected_retention_key?(job_id, &1)),
         commands <- Enum.map(keys, &["EXPIRE", &1, to_string(ttl_seconds)]),
         {:ok, _results} <- pipeline(commands) do
      :ok
    else
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  @doc false
  def protected_retention_key?(job_id, candidate) do
    Enum.any?(["signals", "command", "commands", "checkpoint"], fn part ->
      prefix = RedisStore.storage_key(["job", job_id, part])
      candidate == prefix or String.starts_with?(candidate, prefix <> ":")
    end)
  end

  defp ensure_delivery_group(stream_key, stream_ttl_seconds) do
    case command([
           "XGROUP",
           "CREATE",
           stream_key,
           @delivery_consumer_group,
           "0",
           "MKSTREAM"
         ]) do
      {:ok, "OK"} ->
        case command(["EXPIRE", stream_key, to_string(stream_ttl_seconds)]) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, format_reason(reason)}
        end

      {:error, %Redix.Error{message: message}} when is_binary(message) ->
        if String.contains?(message, "BUSYGROUP"), do: :ok, else: {:error, message}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, {:unexpected_delivery_group_result, other}}
    end
  end

  defp maybe_ensure_delivery_group(stream_key, stream_ttl_seconds, true),
    do: ensure_delivery_group(stream_key, stream_ttl_seconds)

  defp maybe_ensure_delivery_group(_stream_key, _stream_ttl_seconds, false), do: :ok

  defp claim_stale_deliveries(stream_key, consumer, lease_ms, count) when count > 0 do
    case command([
           "XAUTOCLAIM",
           stream_key,
           @delivery_consumer_group,
           consumer,
           to_string(lease_ms),
           "0-0",
           "COUNT",
           to_string(count)
         ]) do
      {:ok, [_next_start, entries | _deleted]} -> {:ok, parse_delivery_entries(entries)}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_claim_result, other}}
    end
  end

  defp claim_stale_deliveries(_stream_key, _consumer, _lease_ms, _count), do: {:ok, []}

  defp maybe_claim_stale_deliveries(stream_key, consumer, lease_ms, count, true),
    do: claim_stale_deliveries(stream_key, consumer, lease_ms, count)

  defp maybe_claim_stale_deliveries(_stream_key, _consumer, _lease_ms, _count, false),
    do: {:ok, []}

  defp read_new_deliveries(stream_key, consumer, count) when count > 0 do
    case command([
           "XREADGROUP",
           "GROUP",
           @delivery_consumer_group,
           consumer,
           "COUNT",
           to_string(count),
           "STREAMS",
           stream_key,
           ">"
         ]) do
      {:ok, nil} -> {:ok, []}
      {:ok, [[^stream_key, entries]]} -> {:ok, parse_delivery_entries(entries)}
      {:error, reason} -> {:error, format_reason(reason)}
      other -> {:error, {:unexpected_delivery_read_result, other}}
    end
  end

  defp read_new_deliveries(_stream_key, _consumer, _count), do: {:ok, []}

  defp parse_delivery_entries(entries) when is_list(entries) do
    Enum.map(entries, fn [stream_id, fields] ->
      fields = pairs_to_map(fields)

      %{
        stream_id: stream_id,
        message_id: fields["message_id"],
        payload: fields["payload"]
      }
    end)
  end

  defp pairs_to_map(values) when is_list(values) do
    values
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, value] -> {key, value} end)
  end

  defp prepare_delivery(job_id, agent_id, consumer, entry, now_ms, max_attempts) do
    receipt_key = delivery_receipt_key(job_id, agent_id, entry.message_id)

    script = """
    local pending = redis.call('xpending', KEYS[2], ARGV[4], ARGV[5], ARGV[5], 1)
    if #pending == 0 or pending[1][2] ~= ARGV[3] then return {'owner_changed', '0'} end
    if redis.call("exists", KEYS[1]) == 0 then
      return {"missing", "0"}
    end
    local status = redis.call("hget", KEYS[1], "status") or "unknown"
    if status == "acked" or status == "dead_letter" then
      return {status, redis.call("hget", KEYS[1], "attempts") or "0"}
    end
    local deadline_ms = tonumber(redis.call("hget", KEYS[1], "deadline_ms") or "0")
    if deadline_ms > 0 and tonumber(ARGV[1]) > deadline_ms then
      return {"expired", redis.call("hget", KEYS[1], "attempts") or "0"}
    end
    local attempts = redis.call("hincrby", KEYS[1], "attempts", 1)
    if attempts > tonumber(ARGV[2]) then
      return {"attempts_exhausted", tostring(attempts)}
    end
    redis.call("hset", KEYS[1], "status", "processing", "consumer", ARGV[3])
    return {"deliver", tostring(attempts)}
    """

    case command([
           "EVAL",
           script,
           "2",
           receipt_key,
           delivery_stream_key(job_id, agent_id),
           to_string(now_ms),
           to_string(max_attempts),
           consumer,
           @delivery_consumer_group,
           entry.stream_id
         ]) do
      {:ok, ["owner_changed", _]} ->
        {:error, :delivery_owner_changed}

      {:ok, ["deliver", attempts]} ->
        case Jason.decode(entry.payload) do
          {:ok, message} ->
            {:ok,
             Map.merge(entry, %{
               message: message,
               attempt: parse_redis_integer(attempts)
             })}

          {:error, reason} ->
            {:discard, Map.merge(entry, %{discard_reason: {:invalid_payload, reason}})}
        end

      {:ok, [reason, attempts]}
      when reason in ["missing", "acked", "dead_letter", "expired", "attempts_exhausted"] ->
        {:discard,
         Map.merge(entry, %{
           discard_reason: String.to_atom(reason),
           message:
             case Jason.decode(entry.payload) do
               {:ok, value} -> value
               _ -> %{}
             end,
           attempt: parse_redis_integer(attempts)
         })}

      {:error, reason} ->
        {:error, format_reason(reason)}

      other ->
        {:error, {:unexpected_delivery_prepare_result, other}}
    end
  end

  defp parse_delivery_receipt(receipt) do
    receipt
    |> Map.update("attempts", 0, &parse_redis_integer/1)
    |> Map.update("deadline_ms", 0, &parse_redis_integer/1)
    |> Map.update("enqueued_at_ms", 0, &parse_redis_integer/1)
  end

  defp parse_redis_integer(value) when is_integer(value), do: value

  defp parse_redis_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp parse_redis_integer(_value), do: 0

  defp delivery_stream_key(job_id, agent_id),
    do: key("job", job_id, "agent", agent_id, "deliveries")

  defp delivery_receipt_key(job_id, agent_id, message_id),
    do: key("job", job_id, "delivery", agent_id, message_id)

  defp delivery_agent_count_key(job_id, agent_id),
    do: key("job", job_id, "delivery_count", agent_id)

  defp delivery_job_count_key(job_id, "__mn_command__/" <> _),
    do: key("job", job_id, "command_count")

  defp delivery_job_count_key(job_id, "__mn_control__/" <> _),
    do: key("job", job_id, "control_count")

  defp delivery_job_count_key(job_id, _agent_id), do: key("job", job_id, "delivery_count")
  defp delivery_index_key(job_id), do: key("job", job_id, "delivery_keys")

  defp command(args) do
    protected =
      Enum.any?(args, fn arg ->
        is_binary(arg) and String.starts_with?(arg, RedisStore.storage_key(["job"]) <> ":") and
          String.contains?(arg, ["__mn_command__/", "__mn_control__/"])
      end)

    if protected,
      do: MirrorNeuron.Persistence.ProtectedRedis.command("controls", args),
      else: RedisStore.storage_command(args)
  end

  defp pipeline([]), do: {:ok, []}
  defp pipeline(commands), do: RedisStore.storage_pipeline(commands)

  defp wait_for_replicas(agent_id) do
    if String.starts_with?(agent_id, ["__mn_command__/", "__mn_control__/"]),
      do: MirrorNeuron.Persistence.ProtectedRedis.barrier("controls"),
      else: RedisStore.storage_barrier()
  end

  defp format_reason(reason), do: reason
  defp key(a, b, c), do: RedisStore.storage_key([a, b, c])
  defp key(a, b, c, d), do: RedisStore.storage_key([a, b, c, d])
  defp key(a, b, c, d, e), do: RedisStore.storage_key([a, b, c, d, e])
end
