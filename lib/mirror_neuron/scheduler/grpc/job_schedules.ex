defmodule MirrorNeuron.Grpc.Handlers.JobSchedules do
  @moduledoc "Creates idempotent stable Job schedules on their execution owner."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Runtime.Idempotency
  alias MirrorNeuron.Grpc.JobProjection
  alias MirrorNeuron.Grpc.Handlers.Job.Remote
  alias MirrorNeuron.Grpc.Handlers.Support

  def create_job_schedule(request, stream) do
    case Remote.remote_job_owner(request.job_id) do
      nil -> create_local_job_schedule(request)
      owner -> Remote.forward_call(owner, :create_job_schedule, request, stream)
    end
  end

  defp create_local_job_schedule(request) do
    schedule = Support.decode_json_map(request.schedule_json)
    source = Support.decode_json_map(request.source_json)

    result =
      Idempotency.run(
        "create-job-schedule:#{request.job_id}",
        request.idempotency_key,
        {request.schedule_json, request.source_json},
        fn -> MirrorNeuron.create_job_schedule(request.job_id, schedule, source: source) end
      )

    case result do
      {:ok, created} -> Encoding.response(JobProjection.schedule(created))
      error -> Encoding.respond(error)
    end
  end
end
