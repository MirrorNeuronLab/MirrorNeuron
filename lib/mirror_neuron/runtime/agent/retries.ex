defmodule MirrorNeuron.Runtime.AgentWorker.Retries do
  @moduledoc "Independent delivery retry deadlines and the periodic stale-lease scan."

  alias MirrorNeuron.Runtime.Delivery

  def delivery_reclaim_due?(state) do
    state.reclaim_deliveries? or
      System.monotonic_time(:millisecond) >= next_delivery_reclaim_at(state)
  end

  defp next_delivery_reclaim_at(state) do
    Enum.reduce(state.delivery_retries, state.next_delivery_reclaim_at_ms, fn {_id, at}, next ->
      min(at, next)
    end)
  end

  def mark_delivery_poll_succeeded(state, reclaim?) do
    next_reclaim_at_ms =
      if reclaim? do
        System.monotonic_time(:millisecond) + Delivery.lease_ms()
      else
        state.next_delivery_reclaim_at_ms
      end

    %{
      state
      | reclaim_deliveries?: false,
        delivery_group_ready?: true,
        next_delivery_reclaim_at_ms: next_reclaim_at_ms
    }
  end

  def schedule_delivery_reclaim(state, {:ok, delay_ms}, delivery)
      when is_integer(delay_ms) and delay_ms >= 0 do
    %{
      state
      | reclaim_deliveries?: false,
        delivery_retries:
          Map.put(
            state.delivery_retries,
            delivery.stream_id,
            System.monotonic_time(:millisecond) + delay_ms
          )
    }
  end

  def schedule_delivery_reclaim(state, _retry_result, _delivery), do: state

  def forget_delivery_retry(state, delivery) do
    %{state | delivery_retries: Map.delete(state.delivery_retries, delivery.stream_id)}
  end

  def retry_delay({:ok, delay_ms}) when is_integer(delay_ms), do: delay_ms

  def retry_delay(_result), do: nil
end
