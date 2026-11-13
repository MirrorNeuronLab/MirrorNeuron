defmodule MirrorNeuron.Monitor do
  @moduledoc "Public runtime monitoring and inspection API."

  alias MirrorNeuron.Monitor.Actions
  alias MirrorNeuron.Monitor.Bounds
  alias MirrorNeuron.Monitor.Metrics
  alias MirrorNeuron.Monitor.Queries

  defdelegate list_jobs(), to: Queries
  defdelegate list_jobs(opts), to: Queries
  defdelegate job_details(job_id), to: Queries
  defdelegate job_details(job_id, opts), to: Queries
  defdelegate bound_job_details(details), to: Bounds
  defdelegate bound_job_details(details, max_bytes), to: Bounds
  defdelegate cluster_overview(), to: Metrics
  defdelegate cluster_overview(opts), to: Metrics
  defdelegate clear_jobs(), to: Actions
  defdelegate metrics(), to: Metrics
  defdelegate dead_letters(job_id), to: Actions
  defdelegate replay_dead_letter(job_id, index), to: Actions
end
