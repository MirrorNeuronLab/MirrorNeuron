defmodule MirrorNeuron.Runtime.JobCoordinator.RecoveryTasks do
  @moduledoc "Owns asynchronous rescheduling tasks and their cancellation."

  require Logger

  def start_reschedule_task(state, [], _reason), do: state

  def start_reschedule_task(state, affected_agent_ids, reason) do
    work = fn ->
      MirrorNeuron.Cluster.Reconciler.reschedule_agents(
        state.job_id,
        affected_agent_ids,
        reason: reason,
        skip_reschedule_policy: true,
        skip_reschedule_policy_record: true
      )
    end

    task = start_owned_recovery_task(work)
    %{state | recovery_tasks: Map.put(state.recovery_tasks, task.ref, task)}
  end

  def start_owned_recovery_task(work) do
    task = fn ->
      try do
        work.()
      rescue
        exception -> {:recovery_task_crashed, {:error, exception, __STACKTRACE__}}
      catch
        kind, reason -> {:recovery_task_crashed, {kind, reason, __STACKTRACE__}}
      end
    end

    case Process.whereis(MirrorNeuron.Runtime.RecoveryTaskSupervisor) do
      nil -> Task.async(task)
      _pid -> Task.Supervisor.async(MirrorNeuron.Runtime.RecoveryTaskSupervisor, task)
    end
  end

  def maybe_log_recovery_task_failure(
        job_id,
        {:recovery_task_crashed, {kind, reason, stacktrace}}
      ) do
    Logger.warning(
      "recovery task for job #{job_id} crashed: #{Exception.format(kind, reason, stacktrace)}"
    )
  end

  def maybe_log_recovery_task_failure(_job_id, _result), do: :ok

  def drop_recovery_task(state, ref) do
    %{state | recovery_tasks: Map.delete(state.recovery_tasks, ref)}
  end

  def cancel_recovery_tasks(state) do
    Enum.each(state.recovery_tasks, fn {_ref, task} -> Task.shutdown(task, :brutal_kill) end)
    %{state | recovery_tasks: %{}}
  end
end
