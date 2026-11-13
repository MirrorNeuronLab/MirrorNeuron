defmodule MirrorNeuron.Runtime.JobCoordinator do
  use GenServer

  @moduledoc "Per-run GenServer; domain modules execute callbacks in the owning coordinator process."

  alias MirrorNeuron.Runtime.JobCoordinator.Bootstrap
  alias MirrorNeuron.Runtime.JobCoordinator.Commands
  alias MirrorNeuron.Runtime.JobCoordinator.Health
  alias MirrorNeuron.Runtime.Naming
  alias MirrorNeuron.Runtime.JobCoordinator.Notifications
  alias MirrorNeuron.Runtime.JobCoordinator.Policy
  alias MirrorNeuron.Runtime.JobCoordinator.RecoveryTasks
  alias MirrorNeuron.Runtime.JobCoordinator.Reports

  @impl true
  defdelegate init(args), to: Bootstrap

  @impl true
  defdelegate handle_continue(action, state), to: Bootstrap

  @impl true
  defdelegate handle_call(request, from, state), to: Commands

  @impl true
  defdelegate handle_cast(message, state), to: Notifications

  @impl true
  defdelegate handle_info(message, state), to: Notifications

  def start_link({job_id, manifest, opts}) do
    GenServer.start_link(__MODULE__, {job_id, manifest, opts}, name: Naming.via_job(job_id))
  end

  @impl true
  def terminate(_reason, state) do
    MirrorNeuron.Runtime.SubmissionPreparation.stop(state)
    if task = Map.get(state, :pause_cleanup_task), do: Task.shutdown(task, :brutal_kill)

    state
    |> Health.cancel_health_check_timer()
    |> Reports.cancel_coordinator_delivery_timer()
    |> Policy.cancel_policy_timers()
    |> RecoveryTasks.cancel_recovery_tasks()

    :ok
  end
end
