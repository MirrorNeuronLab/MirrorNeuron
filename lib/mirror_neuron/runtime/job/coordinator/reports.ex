defmodule MirrorNeuron.Runtime.JobCoordinator.Reports do
  @moduledoc "Durable coordinator report polling, leases and acknowledgements."

  require Logger

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.JobCoordinator.Notifications

  def poll_coordinator_deliveries(state) do
    reclaim? = coordinator_delivery_reclaim_due?(state)
    coordinator_agent_id = Delivery.coordinator_agent_id()

    case Delivery.read(
           state.job_id,
           coordinator_agent_id,
           state.coordinator_delivery_consumer,
           reclaim: state.coordinator_delivery_reclaim?,
           claim_stale: reclaim?,
           ensure_group: not state.coordinator_delivery_group_ready?
         ) do
      {:ok, []} ->
        next_state = mark_coordinator_delivery_poll_succeeded(state, reclaim?)
        {:noreply, schedule_coordinator_delivery_poll(next_state, Delivery.poll_ms())}

      {:ok, [delivery | _rest]} ->
        state = mark_coordinator_delivery_poll_succeeded(state, reclaim?)
        process_coordinator_delivery(delivery, state)

      {:error, reason} ->
        Logger.warning("failed to poll durable coordinator reports",
          job_id: state.job_id,
          reason: inspect(reason)
        )

        next_state = %{state | coordinator_delivery_group_ready?: false}
        {:noreply, schedule_coordinator_delivery_poll(next_state, Delivery.poll_ms())}
    end
  end

  defp process_coordinator_delivery(%{discard_reason: reason} = delivery, state) do
    _result =
      Delivery.dead_letter(
        state.job_id,
        Delivery.coordinator_agent_id(),
        delivery,
        reason
      )

    {:noreply, schedule_coordinator_delivery_poll(state, 0)}
  end

  defp process_coordinator_delivery(delivery, state) do
    renewer =
      Delivery.start_lease_renewer(
        state.job_id,
        Map.get(delivery, :storage_agent_id, Delivery.coordinator_agent_id()),
        state.coordinator_delivery_consumer,
        delivery.stream_id
      )

    result = dispatch_coordinator_report(Message.body(delivery.message), state)
    Delivery.stop_lease_renewer(renewer)

    case result do
      {:error, reason} ->
        _result =
          Delivery.dead_letter(
            state.job_id,
            Delivery.coordinator_agent_id(),
            delivery,
            reason
          )

        {:noreply, schedule_coordinator_delivery_poll(state, 0)}

      callback ->
        finish_coordinator_delivery(delivery, callback, state)
    end
  end

  defp dispatch_coordinator_report(
         %{
           "kind" => "agent_event",
           "agent_id" => agent_id,
           "event_type" => event_type,
           "payload" => payload
         },
         state
       ) do
    Notifications.handle_info({:agent_event, agent_id, event_type, payload}, state)
  end

  defp dispatch_coordinator_report(
         %{
           "kind" => "workflow_message_received",
           "agent_id" => agent_id,
           "message" => message
         },
         state
       ) do
    Notifications.handle_info({:workflow_message_received, agent_id, message}, state)
  end

  defp dispatch_coordinator_report(
         %{
           "kind" => "workflow_message_acked",
           "agent_id" => agent_id,
           "message" => message
         },
         state
       ) do
    Notifications.handle_info({:workflow_message_acked, agent_id, message}, state)
  end

  defp dispatch_coordinator_report(
         %{"kind" => "agent_completed_run", "agent_id" => agent_id, "result" => result},
         state
       ) do
    Notifications.handle_info({:agent_completed_run, agent_id, result}, state)
  end

  defp dispatch_coordinator_report(
         %{
           "kind" => "agent_delivery_exhausted",
           "agent_id" => agent_id,
           "message_id" => message_id
         },
         state
       ) do
    Notifications.handle_info({:agent_delivery_exhausted, agent_id, message_id}, state)
  end

  defp dispatch_coordinator_report(report, _state),
    do: {:error, {:invalid_coordinator_report, report}}

  defp finish_coordinator_delivery(delivery, callback, state) do
    ack_result =
      Delivery.ack(
        state.job_id,
        Delivery.coordinator_agent_id(),
        state.coordinator_delivery_consumer,
        delivery
      )

    if ack_result != :ok do
      Logger.warning("failed to acknowledge durable coordinator report",
        job_id: state.job_id,
        message_id: delivery.message_id,
        reason: inspect(ack_result)
      )
    end

    case callback do
      {:noreply, next_state} ->
        {:noreply, schedule_coordinator_delivery_poll(next_state, 0)}

      {:stop, reason, next_state} ->
        {:stop, reason, next_state}

      other ->
        Logger.error("invalid coordinator report callback",
          job_id: state.job_id,
          callback: inspect(other)
        )

        {:noreply, schedule_coordinator_delivery_poll(state, Delivery.poll_ms())}
    end
  end

  defp coordinator_delivery_reclaim_due?(state) do
    state.coordinator_delivery_reclaim? or
      System.monotonic_time(:millisecond) >= state.coordinator_delivery_next_reclaim_at_ms
  end

  defp mark_coordinator_delivery_poll_succeeded(state, reclaim?) do
    next_reclaim_at_ms =
      if reclaim? do
        System.monotonic_time(:millisecond) + Delivery.lease_ms()
      else
        state.coordinator_delivery_next_reclaim_at_ms
      end

    %{
      state
      | coordinator_delivery_reclaim?: false,
        coordinator_delivery_group_ready?: true,
        coordinator_delivery_next_reclaim_at_ms: next_reclaim_at_ms
    }
  end

  def schedule_coordinator_delivery_poll(state, delay_ms) do
    state = cancel_coordinator_delivery_timer(state)
    token = make_ref()

    timer_ref =
      Process.send_after(self(), {:coordinator_delivery_poll, token}, max(delay_ms, 0))

    %{
      state
      | coordinator_delivery_timer_ref: timer_ref,
        coordinator_delivery_token: token
    }
  end

  def cancel_coordinator_delivery_timer(
        %{
          coordinator_delivery_timer_ref: ref,
          coordinator_delivery_token: token
        } = state
      )
      when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:coordinator_delivery_poll, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_coordinator_delivery_timer(state)
  end

  def cancel_coordinator_delivery_timer(state), do: state

  def clear_coordinator_delivery_timer(state) do
    %{
      state
      | coordinator_delivery_timer_ref: nil,
        coordinator_delivery_token: nil
    }
  end
end
