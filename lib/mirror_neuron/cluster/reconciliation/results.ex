defmodule MirrorNeuron.Cluster.Reconciler.Results do
  @moduledoc "Stable recovery outcomes, per-job failure isolation and aggregate counters."

  def safe_job_result(job, context, fun) do
    fun.()
  rescue
    error ->
      failed(job, "#{context} exception: #{Exception.message(error)}")
  catch
    kind, reason ->
      failed(job, "#{context} #{kind}: #{inspect(reason)}")
  end

  def skipped(job, reason), do: %{job_id: result_job_id(job), action: :skipped, reason: reason}

  def failed(job, reason), do: %{job_id: result_job_id(job), action: :failed, reason: reason}

  def blocked(job, reason, extra),
    do: Map.merge(%{job_id: result_job_id(job), action: :blocked, reason: reason}, extra)

  def paused(job, reason, extra),
    do:
      Map.merge(%{job_id: result_job_id(job), action: :paused_for_review, reason: reason}, extra)

  def recovered(job, reason, extra),
    do: Map.merge(%{job_id: result_job_id(job), action: :recovered, reason: reason}, extra)

  defp result_job_id(job) when is_map(job), do: Map.get(job, "job_id") || Map.get(job, :job_id)

  defp result_job_id(_job), do: nil

  def record(acc, result) do
    acc
    |> Map.update!(:checked, &(&1 + 1))
    |> Map.update!(:jobs, &[result | &1])
    |> bump(result.action)
  end

  defp bump(acc, :recovered), do: Map.update!(acc, :recovered, &(&1 + 1))

  defp bump(acc, :paused_for_review), do: Map.update!(acc, :paused, &(&1 + 1))

  defp bump(acc, :blocked), do: Map.update!(acc, :blocked, &(&1 + 1))

  defp bump(acc, :failed), do: Map.update!(acc, :failed, &(&1 + 1))

  defp bump(acc, _action), do: Map.update!(acc, :skipped, &(&1 + 1))

  def finalize_result(result), do: Map.update!(result, :jobs, &Enum.reverse/1)
end
