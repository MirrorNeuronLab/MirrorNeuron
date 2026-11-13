defmodule MirrorNeuron.Runtime.AgentWorker.Timers do
  @moduledoc "Token-scoped delivery polls and heartbeat timers owned by one worker."

  @default_heartbeat_interval_ms 30_000

  def schedule_delivery_poll(%{paused?: true} = state, _delay_ms),
    do: cancel_delivery_timer(state)

  def schedule_delivery_poll(state, delay_ms) do
    state = cancel_delivery_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:delivery_poll, token}, max(delay_ms, 0))
    %{state | delivery_timer_ref: timer_ref, delivery_token: token}
  end

  def cancel_delivery_timer(%{delivery_timer_ref: ref, delivery_token: token} = state)
      when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:delivery_poll, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_delivery_timer(state)
  end

  def cancel_delivery_timer(state), do: state

  def clear_delivery_timer(state),
    do: %{state | delivery_timer_ref: nil, delivery_token: nil}

  def heartbeat_interval_ms do
    Application.get_env(
      :mirror_neuron,
      :agent_heartbeat_interval_ms,
      @default_heartbeat_interval_ms
    )
  end

  def schedule_heartbeat(%{heartbeat_interval_ms: interval_ms} = state)
      when is_integer(interval_ms) and interval_ms > 0 do
    state = cancel_heartbeat_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:heartbeat, token}, interval_ms)
    %{state | heartbeat_timer_ref: timer_ref, heartbeat_token: token}
  end

  def schedule_heartbeat(state), do: cancel_heartbeat_timer(state)

  def cancel_heartbeat_timer(%{heartbeat_timer_ref: ref, heartbeat_token: token} = state)
      when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:heartbeat, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_heartbeat_timer(state)
  end

  def cancel_heartbeat_timer(state), do: state

  def clear_heartbeat_timer(state),
    do: %{state | heartbeat_timer_ref: nil, heartbeat_token: nil}
end
