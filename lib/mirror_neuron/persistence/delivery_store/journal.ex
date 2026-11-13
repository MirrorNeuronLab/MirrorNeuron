defmodule MirrorNeuron.Persistence.DeliveryStore.Journal do
  @moduledoc "Persists invocation ownership, immutable outboxes and agent checkpoints."

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

  def read_outbox(job_id, agent_id, message_id) do
    Transport.command(["HGET", Keys.delivery_receipt_key(job_id, agent_id, message_id), "outbox"])
  end

  def begin_invocation(job_id, agent_id, message_id, consumer, service_resume_token \\ nil) do
    script =
      @ownership_check <>
        """
        if not owns_receipt(KEYS[1], KEYS[2], ARGV[2], ARGV[1]) then return 'owner_changed' end
        local phase = redis.call('hget', KEYS[1], 'invocation')
        -- A supervisor may restart a confirmed-stopped, owned service once.
        -- Reclaiming the delivery or restarting its consumer cannot mint another grant.
        local resume = ARGV[3]
        if phase and (phase ~= 'executing' or resume == '' or
             redis.call('hexists', KEYS[1], 'resume:' .. resume) == 1) then return phase end
        if resume ~= '' then redis.call('hset', KEYS[1], 'resume:' .. resume, '1') end
        redis.call('hset', KEYS[1], 'invocation', 'executing')
        return 'started'
        """

    with {:ok, phase} <-
           Transport.command([
             "EVAL",
             script,
             "2",
             Keys.delivery_receipt_key(job_id, agent_id, message_id),
             Keys.delivery_stream_key(job_id, agent_id),
             consumer,
             @delivery_consumer_group,
             service_resume_token || ""
           ]),
         :ok <- Transport.wait_for_replicas(agent_id),
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

    Transport.command([
      "EVAL",
      script,
      "2",
      Keys.delivery_receipt_key(job_id, agent_id, message_id),
      Keys.delivery_stream_key(job_id, agent_id),
      consumer,
      @delivery_consumer_group
    ])
  end

  def read_checkpoint(job_id, agent_id, epoch) do
    Transport.command(["GET", Keys.checkpoint_key(job_id, agent_id, epoch)])
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

    case Transport.command([
           "EVAL",
           script,
           "4",
           Keys.delivery_receipt_key(job_id, agent_id, message_id),
           Keys.checkpoint_key(job_id, logical_agent, epoch),
           Keys.delivery_index_key(job_id),
           Keys.delivery_stream_key(job_id, agent_id),
           encoded,
           consumer,
           checkpoint,
           @delivery_consumer_group
         ]) do
      {:ok, 1} -> Transport.wait_for_replicas(agent_id)
      {:ok, _} -> {:error, :outbox_conflict}
      error -> error
    end
  end
end
