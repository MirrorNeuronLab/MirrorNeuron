defmodule MirrorNeuron.Persistence.DeliveryStore.Enqueue do
  @moduledoc "Atomically deduplicates and admits deliveries under agent and Job queue limits."

  alias MirrorNeuron.Persistence.DeliveryStore.Decoding
  alias MirrorNeuron.Persistence.DeliveryStore.Keys
  alias MirrorNeuron.Persistence.DeliveryStore.Transport

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

    receipt_key = Keys.delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = Keys.delivery_stream_key(job_id, agent_id)
    agent_count_key = Keys.delivery_agent_count_key(job_id, agent_id)
    job_count_key = Keys.delivery_job_count_key(job_id, agent_id)
    index_key = Keys.delivery_index_key(job_id)

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

    case Transport.command(args) do
      {:ok, ["queued", _status, stream_id]} ->
        with :ok <- Transport.wait_for_replicas(agent_id),
             do: {:ok, %{status: :queued, stream_id: stream_id, message_id: message_id}}

      {:ok, ["duplicate", status, stream_id]} ->
        with :ok <- Transport.wait_for_replicas(agent_id),
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
        {:error, {:delivery_backpressure, :agent, Decoding.parse_redis_integer(count)}}

      {:ok, ["job_full", count, _stream_id]} ->
        {:error, {:delivery_backpressure, :job, Decoding.parse_redis_integer(count)}}

      {:error, reason} ->
        {:error, Transport.format_reason(reason)}

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
end
