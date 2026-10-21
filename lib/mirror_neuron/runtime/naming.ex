defmodule MirrorNeuron.Runtime.Naming do
  def via_job(job_id),
    do: {:via, Horde.Registry, {MirrorNeuron.DistributedRegistry, {:job, job_id}}}

  def via_workflow_budget(job_id, run_id),
    do:
      {:via, Horde.Registry,
       {MirrorNeuron.DistributedRegistry, {:workflow_budget, job_id, run_id}}}

  def via_job_runner(job_id),
    do: {:via, Horde.Registry, {MirrorNeuron.DistributedRegistry, {:job_runner, job_id}}}

  def via_agent(job_id, agent_id),
    do: {:via, Horde.Registry, {MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}}}
end
