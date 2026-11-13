defmodule MirrorNeuron.Runtime.MessageDelivery do
  @moduledoc "Durable delivery admission and best-effort consumer wakeups."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.JobCalls

  def deliver(job_id, agent_id, message, opts \\ []) do
    case Delivery.enqueue(job_id, agent_id, message, opts) do
      {:ok, receipt} ->
        wake_delivery_consumer(job_id, agent_id)

        EventBus.publish(job_id, %{
          type: :message_queued,
          agent_id: agent_id,
          message_id: receipt.message_id,
          duplicate: receipt.status == :duplicate,
          timestamp: Runtime.timestamp()
        })

        :ok

      {:error, {:delivery_backpressure, scope, count}} ->
        details = %{
          "reason" => "durable_delivery_queue_full",
          "job_id" => job_id,
          "agent_id" => agent_id,
          "scope" => to_string(scope),
          "pending" => count,
          "dropped" => false,
          "retry_after_ms" => Delivery.poll_ms()
        }

        EventBus.publish(job_id, %{
          type: :backpressure_rejected,
          agent_id: agent_id,
          payload: details,
          timestamp: Runtime.timestamp()
        })

        {:error, {:backpressure, details}}

      {:error, reason} ->
        {:error, {:delivery_enqueue_failed, reason}}
    end
  end

  defp wake_delivery_consumer(job_id, agent_id) do
    case JobCalls.safe_registry_lookup({:agent, job_id, agent_id}) do
      {:ok, [{pid, _meta} | _]} -> GenServer.cast(pid, :delivery_available)
      _missing_or_unavailable -> :ok
    end
  end
end
