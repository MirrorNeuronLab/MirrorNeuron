defmodule MirrorNeuron.Runtime.RunRetry do
  @moduledoc "Operator-authorized retries from verified logical checkpoints."

  alias MirrorNeuron.Runtime.RunRetry.Checkpoints
  alias MirrorNeuron.Runtime.RunRetry.Invocation
  alias MirrorNeuron.Runtime.RunRetry.Planner
  alias MirrorNeuron.Runtime.RunRetry.Submission

  defdelegate invocation_config(config, context), to: Invocation
  defdelegate checkpoint(job, ledger), to: Checkpoints
  defdelegate checkpoint(job, ledger, artifacts), to: Checkpoints
  defdelegate definition_identity(manifest, inputs), to: Checkpoints
  defdelegate checkpoint(job, ledger, artifacts, arg4), to: Checkpoints
  defdelegate plan(run_id), to: Planner
  defdelegate plan(run_id, overrides), to: Planner
  defdelegate submit(run_id, attrs), to: Submission
  defdelegate dispatch_queued(job), to: Submission
  defdelegate begin_attempt(job_id, manifest, arg3, lease), to: Submission
  defdelegate digest(value), to: Checkpoints
end
