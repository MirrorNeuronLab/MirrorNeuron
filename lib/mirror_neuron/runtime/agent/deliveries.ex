defmodule MirrorNeuron.Runtime.AgentWorker.Deliveries do
  @moduledoc "Polls durable deliveries and settles ACK, defer, retry and exhaustion receipts."

  require Logger

  alias MirrorNeuron.Runtime.AgentWorker.Invocation
  alias MirrorNeuron.Runtime.AgentWorker.Observations
  alias MirrorNeuron.Runtime.AgentWorker.Reports
  alias MirrorNeuron.Runtime.AgentWorker.Retries
  alias MirrorNeuron.Runtime.AgentWorker.Timers
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.ErrorEnvelope

  def poll_deliveries(%{checkpoint_pending?: true} = state) do
    case MirrorNeuron.Runtime.InvocationOutbox.recover(state) do
      {:ok, ready} ->
        poll_deliveries(%{ready | checkpoint_pending?: false})

      {:error, reason} ->
        if reason != :checkpoint_artifact_pending,
          do:
            MirrorNeuron.Runtime.Signals.error(
              state.job_id,
              state.node.node_id,
              "checkpoint",
              reason
            )

        Timers.schedule_delivery_poll(state, Delivery.poll_ms())
    end
  end

  def poll_deliveries(state) do
    reclaim? = Retries.delivery_reclaim_due?(state)

    case Delivery.read(
           state.job_id,
           state.node.node_id,
           state.delivery_consumer,
           command_streak: Map.get(state, :command_streak, 0),
           reclaim: state.reclaim_deliveries?,
           claim_stale: reclaim?,
           ensure_group: not state.delivery_group_ready?
         ) do
      {:ok, []} ->
        state
        |> Retries.mark_delivery_poll_succeeded(reclaim?)
        |> Timers.schedule_delivery_poll(Delivery.poll_ms())

      {:ok, [delivery | _rest]} ->
        state = Retries.mark_delivery_poll_succeeded(state, reclaim?)

        state = %{
          state
          | command_streak:
              MirrorNeuron.Runtime.DeliveryChannels.next_streak(
                delivery.lane,
                state.command_streak
              ),
            delivery_bucket: delivery.storage_agent_id
        }

        delivery
        |> process_delivery(state)
        |> Timers.schedule_delivery_poll(0)

      {:error, reason} ->
        Logger.warning("failed to poll durable message deliveries",
          job_id: state.job_id,
          agent_id: state.node.node_id,
          reason: inspect(reason)
        )

        state
        |> Map.put(:delivery_group_ready?, false)
        |> Timers.schedule_delivery_poll(Delivery.poll_ms())
    end
  end

  defp process_delivery(%{discard_reason: :attempts_exhausted} = delivery, state) do
    # Persist the terminal report before discarding the original delivery, so a
    # coordinator restart cannot lose the transition and leave the Run running.
    case Reports.enqueue_coordinator_report(
           state,
           delivery.message,
           "agent_delivery_exhausted",
           %{"message_id" => delivery.message_id},
           "exhausted"
         ) do
      :ok ->
        discard_delivery(delivery, state)

      {:error, _reason} ->
        Retries.schedule_delivery_reclaim(
          state,
          Delivery.retry(state.job_id, state.node.node_id, state.delivery_consumer, delivery),
          delivery
        )
    end
  end

  defp process_delivery(%{discard_reason: _reason} = delivery, state),
    do: discard_delivery(delivery, state)

  defp process_delivery(delivery, state) do
    state = Retries.forget_delivery_retry(state, delivery)
    message = put_in(delivery.message, ["envelope", "attempt"], delivery.attempt)
    delivery = %{delivery | message: message}

    renewer =
      Delivery.start_lease_renewer(
        state.job_id,
        Map.get(delivery, :storage_agent_id, state.node.node_id),
        state.delivery_consumer,
        delivery.stream_id
      )

    result = Invocation.process_message_result(message, state)

    case result do
      {:ok, next_state} ->
        retry_result =
          case Delivery.ack(
                 state.job_id,
                 state.node.node_id,
                 state.delivery_consumer,
                 delivery
               ) do
            :ok ->
              Delivery.stop_lease_renewer(renewer, :recovered)

              if delivery.attempt > 1 do
                MirrorNeuron.Runtime.Signals.resolve(
                  state.job_id,
                  state.node.node_id,
                  delivery.message_id
                )

                MirrorNeuron.Runtime.Signals.resolve(
                  state.job_id,
                  state.node.node_id,
                  "worker-exit"
                )
              end

              Observations.persist_observation(next_state)

              send(state.coordinator, {
                :agent_event,
                state.node.node_id,
                :message_acked,
                %{"message_id" => delivery.message_id, "attempt" => delivery.attempt}
              })

              :no_retry

            {:error, reason} ->
              Delivery.stop_lease_renewer(renewer)

              MirrorNeuron.Runtime.Signals.error(
                state.job_id,
                state.node.node_id,
                delivery.message_id,
                {:ack_failed, reason}
              )

              report_delivery_retry(delivery, {:ack_failed, reason}, state)
          end

        Retries.schedule_delivery_reclaim(next_state, retry_result, delivery)

      {:defer, _reason, next_state} ->
        Delivery.stop_lease_renewer(renewer)

        Retries.schedule_delivery_reclaim(
          next_state,
          Delivery.defer(state.job_id, state.node.node_id, state.delivery_consumer, delivery),
          delivery
        )

      {:error, reason, next_state} ->
        Delivery.stop_lease_renewer(renewer)

        MirrorNeuron.Runtime.Signals.error(
          state.job_id,
          state.node.node_id,
          delivery.message_id,
          reason
        )

        retry_result = report_delivery_retry(delivery, reason, state)
        send(state.coordinator, {:agent_failed, state.node.node_id, reason})
        Retries.schedule_delivery_reclaim(next_state, retry_result, delivery)
    end
  end

  defp discard_delivery(%{discard_reason: reason} = delivery, state) do
    MirrorNeuron.Runtime.CommandReceipts.fail(Map.get(delivery, :message, %{}), state, reason)
    _result = Delivery.dead_letter(state.job_id, state.node.node_id, delivery, reason)
    Retries.forget_delivery_retry(state, delivery)
  end

  defp report_delivery_retry(delivery, reason, state) do
    MirrorNeuron.Runtime.Signals.error(
      state.job_id,
      state.node.node_id,
      delivery.message_id,
      reason,
      :retrying
    )

    error =
      ErrorEnvelope.normalize(reason, component: "agent_worker", agent_id: state.node.node_id)

    result =
      Delivery.retry(
        state.job_id,
        state.node.node_id,
        state.delivery_consumer,
        delivery
      )

    send(state.coordinator, {
      :agent_event,
      state.node.node_id,
      :message_retry_scheduled,
      %{
        "message_id" => delivery.message_id,
        "attempt" => delivery.attempt,
        "reason" => ErrorEnvelope.desc(error),
        "error" => error,
        "delay_ms" => Retries.retry_delay(result)
      }
    })

    result
  end
end
