defmodule MirrorNeuron.Runtime.JobRunner do
  use Supervisor

  alias MirrorNeuron.Runtime.{JobCoordinator, Naming}

  def child_spec({job_id, manifest, opts}) do
    %{
      id: {:job_runner, job_id},
      start: {__MODULE__, :start_link, [{job_id, manifest, opts}]},
      restart: :transient,
      type: :supervisor
    }
  end

  def start_link({job_id, manifest, opts}) do
    Supervisor.start_link(__MODULE__, {job_id, manifest, opts},
      name: Naming.via_job_runner(job_id)
    )
  end

  @impl true
  def init({job_id, manifest, opts}) do
    children = [
      %{
        id: {JobCoordinator, job_id},
        start: {JobCoordinator, :start_link, [{job_id, manifest, opts}]},
        restart: :temporary
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
