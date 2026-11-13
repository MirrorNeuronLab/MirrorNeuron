defmodule MirrorNeuron.Runtime.SubmissionPreparation do
  @moduledoc false
  alias MirrorNeuron.Artifacts.SubmissionReadiness
  alias MirrorNeuron.Runtime.EventBus

  def status(state) do
    storage = state.submission_storage
    now = System.monotonic_time(:millisecond)

    cond do
      Map.has_key?(storage, :check_result) ->
        result = storage.check_result
        state = %{state | submission_storage: Map.delete(storage, :check_result)}
        apply_result(state, result, now)

      not SubmissionReadiness.managed?(state.manifest) ->
        {:ready, state}

      is_struct(storage[:check_task], Task) ->
        if expired?(storage, now, SubmissionReadiness.timeout_seconds()) do
          Task.shutdown(storage.check_task, :brutal_kill)
          timeout(state, %{"reason" => "readiness_inspection_stalled"}, now)
        else
          {:waiting, state}
        end

      true ->
        manifest = state.manifest

        work = fn ->
          try do
            SubmissionReadiness.verify(manifest)
          rescue
            _ -> {:error, "submission_readiness_inspection_failed", %{}}
          catch
            _, _ -> {:error, "submission_readiness_inspection_failed", %{}}
          end
        end

        task =
          case Process.whereis(MirrorNeuron.Runtime.RecoveryTaskSupervisor) do
            nil -> Task.async(work)
            _ -> Task.Supervisor.async_nolink(MirrorNeuron.Runtime.RecoveryTaskSupervisor, work)
          end

        {:waiting, %{state | submission_storage: Map.put(storage, :check_task, task)}}
    end
  end

  def received(state, result) do
    storage =
      state.submission_storage |> Map.delete(:check_task) |> Map.put(:check_result, result)

    %{state | submission_storage: storage}
  end

  def stop(state) do
    if task = get_in(state, [:submission_storage, :check_task]),
      do: Task.shutdown(task, :brutal_kill)

    state
  end

  # High-water marks cannot be renewed by repeated snapshots, timestamps,
  # fluctuating files or unchanged polling. Byte growth counts before a large
  # file's final digest can be verified; only a ready result dispatches work.
  def progress(storage, metrics, now) do
    bytes = metrics["observed_bytes"] || 0
    verified = max((metrics["total_files"] || 0) - (metrics["remaining_files"] || 0), 0)
    previous_bytes = storage[:observed_bytes] || 0
    previous_verified = storage[:verified_files] || 0

    if bytes > previous_bytes or verified > previous_verified do
      storage
      |> Map.put(:observed_bytes, max(bytes, previous_bytes))
      |> Map.put(:verified_files, max(verified, previous_verified))
      |> Map.put(:last_progress_at_ms, now)
    else
      storage
    end
  end

  def expired?(storage, now, seconds),
    do: now - (storage[:last_progress_at_ms] || storage.started_at_ms) >= seconds * 1000

  defp apply_result(state, {:ready, metrics}, now) do
    if metrics["managed"],
      do: EventBus.publish(state.job_id, event(state, :submission_storage_ready, metrics, now))

    {:ready, %{state | submission_storage: Map.put(state.submission_storage, :timer_token, nil)}}
  end

  defp apply_result(state, {:waiting, metrics}, now) do
    storage = progress(state.submission_storage, metrics, now)
    state = %{state | submission_storage: storage}

    if expired?(storage, now, SubmissionReadiness.timeout_seconds()) do
      timeout(state, metrics, now)
    else
      last = storage[:last_wait_event_at_ms]

      if is_nil(last) or now - last >= SubmissionReadiness.event_interval_ms() do
        EventBus.publish(state.job_id, event(state, :submission_storage_waiting, metrics, now))

        {:waiting,
         %{
           state
           | submission_storage:
               storage |> Map.put(:waiting?, true) |> Map.put(:last_wait_event_at_ms, now)
         }}
      else
        {:waiting, %{state | submission_storage: Map.put(storage, :waiting?, true)}}
      end
    end
  end

  defp apply_result(state, {:error, reason, metrics}, now) do
    EventBus.publish(
      state.job_id,
      event(state, :submission_storage_timeout, Map.put(metrics, "reason", reason), now)
    )

    {:error, reason, state}
  end

  defp timeout(state, metrics, now) do
    seconds = SubmissionReadiness.timeout_seconds()

    details =
      event(state, :submission_storage_timeout, metrics, now)
      |> Map.put(:timeout_seconds, seconds)

    EventBus.publish(state.job_id, details)
    storage = state.submission_storage |> Map.delete(:check_task) |> Map.put(:timer_token, nil)

    {:error,
     "staged inputs were not ready on #{node()} after #{seconds} seconds without progress",
     %{state | submission_storage: storage}}
  end

  defp event(state, type, metrics, now) do
    metrics
    |> Map.put(:type, type)
    |> Map.put(:node, to_string(node()))
    |> Map.put(:elapsed_ms, max(now - state.submission_storage.started_at_ms, 0))
    |> Map.put(:timestamp, MirrorNeuron.Runtime.timestamp())
  end
end
