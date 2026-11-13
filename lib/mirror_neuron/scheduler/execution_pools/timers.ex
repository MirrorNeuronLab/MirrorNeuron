defmodule MirrorNeuron.Execution.LeaseManager.Timers do
  @moduledoc "Schedules and cancels queue deadlines in the owning LeaseManager process."

  def schedule_queue_timeout(_lease_id, timeout_ms) when timeout_ms <= 0, do: nil

  def schedule_queue_timeout(lease_id, timeout_ms) do
    Process.send_after(self(), {:queue_timeout, lease_id}, timeout_ms)
  end

  def cancel_queue_timeout(nil), do: :ok

  def cancel_queue_timeout(%{timeout_ref: timeout_ref, lease_id: lease_id})
      when is_reference(timeout_ref) do
    Process.cancel_timer(timeout_ref)

    receive do
      {:queue_timeout, ^lease_id} -> :ok
    after
      0 -> :ok
    end
  end

  def cancel_queue_timeout(_request), do: :ok
end
