defmodule MirrorNeuron.Execution.LeaseManager.Requests do
  @moduledoc "Builds bounded queue diagnostics and serializable lease metadata."

  def stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
      {normalized_key, stringify_value(value)}
    end)
  end

  def stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value), do: value

  def queue_full?(_pool_state, max_queue_length) when max_queue_length <= 0, do: false

  def queue_full?(pool_state, max_queue_length) do
    :queue.len(pool_state.waiting) >= max_queue_length
  end

  def queue_full_reason(pool, slots, pool_state, max_queue_length) do
    %{
      "reason" => "executor_pool_queue_full",
      "pool" => pool,
      "slots" => slots,
      "queued" => :queue.len(pool_state.waiting),
      "max_queue_length" => max_queue_length,
      "retry_after_ms" => 250
    }
  end

  def queue_timeout_reason(request) do
    %{
      "reason" => "executor_pool_queue_timeout",
      "pool" => request.pool,
      "slots" => request.slots,
      "queue_wait_ms" => max(now_ms() - request.requested_at_ms, 0),
      "timeout_ms" => request.queue_timeout_ms,
      "retry_after_ms" => 250
    }
  end

  def lease_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def now_ms, do: System.monotonic_time(:millisecond)
end
