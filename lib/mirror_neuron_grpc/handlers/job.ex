defmodule MirrorNeuron.Grpc.Handlers.Job do
  @moduledoc "Stable Job and Run gRPC handler API; commands delegate to their owning boundary."

  alias MirrorNeuron.Grpc.Handlers.Job.Definitions
  alias MirrorNeuron.Grpc.Handlers.Job.Inputs
  alias MirrorNeuron.Grpc.Handlers.JobSchedules
  alias MirrorNeuron.Grpc.Handlers.Job.Relocation
  alias MirrorNeuron.Grpc.Handlers.Job.Responses
  alias MirrorNeuron.Grpc.Handlers.Job.Retry
  alias MirrorNeuron.Grpc.Handlers.RunAdmission
  alias MirrorNeuron.Grpc.Handlers.Job.Runs

  defdelegate relocate_job(request, stream), to: Relocation
  defdelegate create_job(request, stream), to: Definitions
  defdelegate get_job(request, stream), to: Definitions
  defdelegate list_jobs(request, stream), to: Definitions
  defdelegate update_job(request, stream), to: Definitions
  defdelegate archive_job(request, stream), to: Definitions
  defdelegate reset_job_data(request, stream), to: Definitions
  defdelegate delete_job(request, stream), to: Definitions
  defdelegate check_run_admission(request, stream), to: RunAdmission
  defdelegate start_run(request, stream), to: Runs
  defdelegate list_runs(request, stream), to: Runs
  defdelegate get_run(request, stream), to: Runs
  defdelegate get_run_control(request, stream), to: Runs
  defdelegate pause_run(request, stream), to: Runs
  defdelegate resume_run(request, stream), to: Runs
  defdelegate plan_run_retry(request, stream), to: Retry
  defdelegate retry_run(request, stream), to: Retry
  defdelegate cancel_run(request, stream), to: Runs
  defdelegate delete_run(request, stream), to: Runs
  defdelegate get_run_input_status(request, stream), to: Inputs
  defdelegate send_run_input(request, stream), to: Inputs
  defdelegate create_job_schedule(request, stream), to: JobSchedules
  defdelegate query_job_response(request, stream), to: Responses
  defdelegate get_job_response_turn(request, stream), to: Responses

  defdelegate list_schedules(request, stream), to: MirrorNeuron.Grpc.Handlers.Schedule

  defdelegate get_schedule(request, stream), to: MirrorNeuron.Grpc.Handlers.Schedule

  defdelegate update_schedule(request, stream), to: MirrorNeuron.Grpc.Handlers.Schedule

  defdelegate delete_schedule(request, stream), to: MirrorNeuron.Grpc.Handlers.Schedule
end
