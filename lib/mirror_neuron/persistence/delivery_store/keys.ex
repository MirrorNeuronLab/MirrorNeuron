defmodule MirrorNeuron.Persistence.DeliveryStore.Keys do
  @moduledoc "Builds delivery lane and checkpoint keys through the public persistence namespace."

  alias MirrorNeuron.Persistence.RedisStore

  def checkpoint_key(job_id, agent_id, epoch),
    do: key("job", job_id, "checkpoint", agent_id, to_string(epoch || 0))

  def delivery_stream_key(job_id, agent_id),
    do: key("job", job_id, "agent", agent_id, "deliveries")

  def delivery_receipt_key(job_id, agent_id, message_id),
    do: key("job", job_id, "delivery", agent_id, message_id)

  def delivery_agent_count_key(job_id, agent_id),
    do: key("job", job_id, "delivery_count", agent_id)

  def delivery_job_count_key(job_id, "__mn_command__/" <> _),
    do: key("job", job_id, "command_count")

  def delivery_job_count_key(job_id, "__mn_control__/" <> _),
    do: key("job", job_id, "control_count")

  def delivery_job_count_key(job_id, _agent_id), do: key("job", job_id, "delivery_count")

  def delivery_index_key(job_id), do: key("job", job_id, "delivery_keys")

  defp key(a, b, c), do: RedisStore.storage_key([a, b, c])

  defp key(a, b, c, d), do: RedisStore.storage_key([a, b, c, d])

  defp key(a, b, c, d, e), do: RedisStore.storage_key([a, b, c, d, e])
end
