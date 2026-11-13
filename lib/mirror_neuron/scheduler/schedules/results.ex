defmodule MirrorNeuron.Scheduler.Schedules.Results do
  @moduledoc "Aggregates schedule processing counters."

  def reduce_results(results) do
    Enum.reduce(results, empty_result(), fn
      {:ok, result}, acc when is_map(result) -> merge_counts(acc, result)
      result, acc when is_map(result) -> merge_counts(acc, result)
      _other, acc -> acc
    end)
  end

  def merge_counts(left, right) do
    Map.merge(left, right, fn
      :event, _left, right ->
        right

      _key, left_value, right_value when is_integer(left_value) and is_integer(right_value) ->
        left_value + right_value

      _key, _left_value, right_value ->
        right_value
    end)
  end

  defp empty_result do
    %{checked: 0, dispatched: 0, skipped: 0, failed: 0, missed: 0, blocked: 0, windows_closed: 0}
  end
end
