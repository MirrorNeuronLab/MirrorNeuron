defmodule MirrorNeuron.Persistence.DeliveryStore do
  @moduledoc "Atomic durable delivery storage and fenced invocation journal API."

  alias MirrorNeuron.Persistence.DeliveryStore.Enqueue
  alias MirrorNeuron.Persistence.DeliveryStore.Journal
  alias MirrorNeuron.Persistence.DeliveryStore.Reading
  alias MirrorNeuron.Persistence.DeliveryStore.Receipts
  alias MirrorNeuron.Persistence.DeliveryStore.Settlement

  defdelegate enqueue_delivery(job_id, agent_id, message, opts), to: Enqueue
  defdelegate read_deliveries(job_id, agent_id, consumer, opts), to: Reading

  defdelegate ack_delivery(job_id, agent_id, consumer, stream_id, message_id, ack_ttl_seconds),
    to: Settlement

  defdelegate dead_letter_delivery(job_id, agent_id, stream_id, message_id, reason, ttl_seconds),
    to: Settlement

  defdelegate renew_delivery(job_id, agent_id, consumer, stream_id), to: Settlement

  defdelegate retry_delivery(job_id, agent_id, consumer, stream_id, delay_ms, lease_ms),
    to: Settlement

  defdelegate defer_delivery(job_id, agent_id, consumer, delivery), to: Settlement
  defdelegate fetch_delivery_receipt(job_id, agent_id, message_id), to: Receipts
  defdelegate read_outbox(job_id, agent_id, message_id), to: Journal
  defdelegate begin_invocation(job_id, agent_id, message_id, consumer), to: Journal

  defdelegate begin_invocation(job_id, agent_id, message_id, consumer, service_resume_token),
    to: Journal

  defdelegate abandon_invocation(job_id, agent_id, message_id, consumer), to: Journal
  defdelegate read_checkpoint(job_id, agent_id, epoch), to: Journal

  defdelegate write_outbox(
                job_id,
                agent_id,
                message_id,
                encoded,
                consumer,
                logical_agent,
                epoch,
                checkpoint
              ),
              to: Journal

  defdelegate delivery_pending_count(job_id, agent_id), to: Receipts
  defdelegate expire_job_deliveries(job_id, ttl_seconds), to: Receipts
  defdelegate protected_retention_key?(job_id, candidate), to: Receipts
end
