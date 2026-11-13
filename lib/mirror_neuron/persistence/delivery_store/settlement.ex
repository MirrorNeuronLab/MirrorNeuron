defmodule MirrorNeuron.Persistence.DeliveryStore.Settlement do
  @moduledoc "Acknowledges, defers and renews deliveries under consumer ownership fences."

  alias MirrorNeuron.Persistence.DeliveryStore.Keys
  alias MirrorNeuron.Persistence.DeliveryStore.Transport

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
  def ack_delivery(job_id, agent_id, consumer, stream_id, message_id, ack_ttl_seconds) do
    receipt_key = Keys.delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = Keys.delivery_stream_key(job_id, agent_id)

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
      Keys.delivery_agent_count_key(job_id, agent_id),
      Keys.delivery_job_count_key(job_id, agent_id),
      Keys.delivery_index_key(job_id),
      consumer,
      to_string(ack_ttl_seconds),
      @delivery_consumer_group,
      stream_id
    ]

    case Transport.command(args) do
      {:ok, 1} -> Transport.wait_for_replicas(agent_id)
      {:ok, 0} -> {:error, :delivery_owner_changed}
      {:error, reason} -> {:error, Transport.format_reason(reason)}
      other -> {:error, {:unexpected_delivery_ack_result, other}}
    end
  end

  @doc false
  def dead_letter_delivery(job_id, agent_id, stream_id, message_id, reason, ttl_seconds) do
    receipt_key = Keys.delivery_receipt_key(job_id, agent_id, message_id)
    stream_key = Keys.delivery_stream_key(job_id, agent_id)

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
      Keys.delivery_agent_count_key(job_id, agent_id),
      Keys.delivery_job_count_key(job_id, agent_id),
      Keys.delivery_index_key(job_id),
      inspect(reason),
      to_string(ttl_seconds),
      @delivery_consumer_group,
      stream_id
    ]

    case Transport.command(args) do
      {:ok, 1} -> Transport.wait_for_replicas(agent_id)
      {:error, command_reason} -> {:error, Transport.format_reason(command_reason)}
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

    case Transport.command([
           "EVAL",
           script,
           "1",
           Keys.delivery_stream_key(job_id, agent_id),
           @delivery_consumer_group,
           consumer,
           stream_id,
           to_string(idle_ms)
         ]) do
      {:ok, [^stream_id]} -> :ok
      {:ok, ["missing"]} -> {:error, :delivery_not_pending}
      {:ok, ["owner_changed"]} -> {:error, :delivery_owner_changed}
      {:error, reason} -> {:error, Transport.format_reason(reason)}
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

    case Transport.command([
           "EVAL",
           script,
           "2",
           Keys.delivery_receipt_key(job_id, agent_id, delivery.message_id),
           Keys.delivery_stream_key(job_id, agent_id),
           consumer,
           @delivery_consumer_group
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :delivery_owner_changed}
      error -> error
    end
  end
end
