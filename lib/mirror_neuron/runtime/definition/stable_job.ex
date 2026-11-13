defmodule MirrorNeuron.Runtime.StableJob do
  @moduledoc """
  Durable configured jobs and their execution runs.

  `job_id` identifies this record and its persistent data. Batch definitions
  retain one-to-many run history. A `type: service` definition retains exactly
  one attached run whose identity survives pause and resume.
  """

  alias MirrorNeuron.Runtime.StableJob.Creation
  alias MirrorNeuron.Runtime.StableJob.Lifecycle
  alias MirrorNeuron.Runtime.StableJob.Queries
  alias MirrorNeuron.Runtime.StableJob.RunManifest
  alias MirrorNeuron.Runtime.StableJob.Runs
  alias MirrorNeuron.Runtime.StableJob.ScheduledService
  alias MirrorNeuron.Runtime.StableJob.Schedules
  alias MirrorNeuron.Runtime.StableJob.StartGate

  defdelegate create(input), to: Creation
  defdelegate create(input, opts), to: Creation
  defdelegate get(job_id), to: Queries
  defdelegate list(), to: Queries
  defdelegate list(opts), to: Queries
  defdelegate list_page(), to: Queries
  defdelegate list_page(opts), to: Queries
  defdelegate update(job_id, attrs), to: Lifecycle
  defdelegate update(job_id, attrs, opts), to: Lifecycle
  defdelegate replace_bundle(job_id, input), to: Lifecycle
  defdelegate replace_bundle(job_id, input, attrs), to: Lifecycle
  defdelegate replace_bundle(job_id, input, attrs, opts), to: Lifecycle
  defdelegate archive(job_id), to: Lifecycle
  defdelegate archive(job_id, opts), to: Lifecycle
  defdelegate start_run(job_id), to: Runs
  defdelegate start_run(job_id, opts), to: Runs
  defdelegate start_run_result(job_id), to: Runs
  defdelegate start_run_result(job_id, opts), to: Runs
  defdelegate scheduled_transition(job_id), to: ScheduledService
  defdelegate scheduled_transition(job_id, opts), to: ScheduledService
  defdelegate list_runs(job_id), to: Queries
  defdelegate list_runs_page(job_id), to: Queries
  defdelegate list_runs_page(job_id, opts), to: Queries
  defdelegate reset_data(job_id), to: Lifecycle
  defdelegate delete(job_id), to: Lifecycle
  defdelegate delete(job_id, opts), to: Lifecycle
  defdelegate delete_run(run_id), to: Runs
  defdelegate delete_run(run_id, opts), to: Runs
  defdelegate attach_schedule(job_id, schedule_id), to: Schedules

  defdelegate prepare_run_manifest(manifest, definition, run_id, data_dir, access),
    to: RunManifest

  defdelegate prepare_run_manifest(manifest, definition, run_id, data_dir, access, opts),
    to: RunManifest

  defdelegate with_start_gate(job_id, callback), to: StartGate
end
