defmodule MirrorNeuron.Runtime do
  @moduledoc "Runtime API for submission, lifecycle control, durable delivery and cleanup."

  alias MirrorNeuron.Runtime.Cleanup
  alias MirrorNeuron.Runtime.ControlErrors
  alias MirrorNeuron.Runtime.ControlSettings
  alias MirrorNeuron.Runtime.JobControl
  alias MirrorNeuron.Runtime.LocalProcesses
  alias MirrorNeuron.Runtime.MessageDelivery
  alias MirrorNeuron.Runtime.Submission

  defdelegate job_call_timeout_ms(), to: ControlSettings
  defdelegate cancel_job_call_timeout_ms(), to: ControlSettings
  defdelegate error_message(reason), to: ControlErrors
  defdelegate start_job(manifest), to: Submission
  defdelegate start_job(manifest, opts), to: Submission
  defdelegate start_admitted_job(job), to: Submission
  defdelegate pause_job(job_id), to: JobControl
  defdelegate resume_job(job_id), to: JobControl
  defdelegate cancel_job(job_id), to: JobControl
  defdelegate terminate_local_job(job_id), to: LocalProcesses
  defdelegate cleanup_jobs(), to: Cleanup
  defdelegate cleanup_jobs(opts), to: Cleanup
  defdelegate clear_job(job_id), to: Cleanup
  defdelegate clear_job_with_result(job_id), to: Cleanup
  defdelegate send_message(job_id, agent_id, message), to: JobControl
  defdelegate cleanup_job_sandboxes(job_id), to: Cleanup
  defdelegate cleanup_job_sandboxes(job_id, job), to: Cleanup
  defdelegate cleanup_job_resources(job_id), to: Cleanup
  defdelegate cleanup_job_resources(job_id, job), to: Cleanup

  defdelegate deploy_agents(job_id, agent_ids, manifest, scheduler_plan, deployment_context),
    to: JobControl

  defdelegate pressure(job_id), to: JobControl
  defdelegate await_completion(job_id, timeout), to: JobControl
  defdelegate deliver(job_id, agent_id, message), to: MessageDelivery
  defdelegate deliver(job_id, agent_id, message, opts), to: MessageDelivery
  defdelegate generate_job_id(graph_id), to: Submission
  defdelegate bundle_ref(manifest, bundle), to: Submission

  def timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
