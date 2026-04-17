defmodule MirrorNeuron.Grpc.JobServer do
  use GRPC.Server, service: Mirrorneuron.Job.V1.JobService.Service

  alias Mirrorneuron.Job.V1.{
    SubmitJobResponse,
    GetJobResponse,
    ListJobsResponse,
    CancelJobResponse,
    PauseJobResponse,
    ResumeJobResponse
  }

  def submit_job(request, _stream) do
    bundle_id = "bundle_#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), bundle_id)
    File.mkdir_p!(tmp_dir)

    File.write!(Path.join(tmp_dir, "manifest.json"), request.manifest_json)

    payloads_dir = Path.join(tmp_dir, "payloads")
    File.mkdir_p!(payloads_dir)

    if request.payloads do
      Enum.each(request.payloads, fn {path, content} ->
        full_path = Path.join(payloads_dir, path)
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, content)
      end)
    end

    case MirrorNeuron.run_manifest(tmp_dir, await: false) do
      {:ok, job_id} ->
        %SubmitJobResponse{job_id: job_id, status: "pending"}

      {:ok, job_id, _job} ->
        %SubmitJobResponse{job_id: job_id, status: "pending"}

      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def get_job(request, _stream) do
    job_id = request.job_id

    case MirrorNeuron.job_details(job_id) do
      {:ok, details_map} ->
        %GetJobResponse{job_json: Jason.encode!(details_map)}

      _ ->
        %GetJobResponse{job_json: "{}"}
    end
  end

  def list_jobs(request, _stream) do
    limit = if request.limit > 0, do: request.limit, else: 100

    case MirrorNeuron.Monitor.list_jobs(limit: limit, include_terminal: request.include_terminal) do
      {:ok, jobs} ->
        %ListJobsResponse{jobs_json: Jason.encode!(%{data: jobs})}

      _ ->
        %ListJobsResponse{jobs_json: "{\"data\": []}"}
    end
  end

  def cancel_job(request, _stream) do
    job_id = request.job_id
    case MirrorNeuron.cancel(job_id) do
      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
      {:ok, status} ->
        %CancelJobResponse{job_id: job_id, status: status}
      _ ->
        %CancelJobResponse{job_id: job_id, status: "cancelled"}
    end
  end

  def pause_job(request, _stream) do
    job_id = request.job_id
    case MirrorNeuron.pause(job_id) do
      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
      {:ok, status} ->
        %PauseJobResponse{job_id: job_id, status: status}
      _ ->
        %PauseJobResponse{job_id: job_id, status: "paused"}
    end
  end

  def resume_job(request, _stream) do
    job_id = request.job_id
    case MirrorNeuron.resume(job_id) do
      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
      {:ok, status} ->
        %ResumeJobResponse{job_id: job_id, status: status}
      _ ->
        %ResumeJobResponse{job_id: job_id, status: "running"}
    end
  end
end

defmodule MirrorNeuron.Grpc.ClusterServer do
  use GRPC.Server, service: Mirrorneuron.Cluster.V1.ClusterService.Service

  alias Mirrorneuron.Cluster.V1.GetSystemSummaryResponse

  def get_system_summary(_request, _stream) do
    case MirrorNeuron.Monitor.cluster_overview() do
      {:ok, overview} ->
        %GetSystemSummaryResponse{summary_json: Jason.encode!(overview)}

      _ ->
        %GetSystemSummaryResponse{summary_json: "{}"}
    end
  end
end

defmodule MirrorNeuron.Grpc.ObservabilityServer do
  use GRPC.Server, service: Mirrorneuron.Observability.V1.ObservabilityService.Service

  alias Mirrorneuron.Observability.V1.EventResponse

  def stream_events(request, stream) do
    job_id = request.job_id

    case MirrorNeuron.events(job_id) do
      {:ok, events} ->
        Enum.each(events, fn ev ->
          GRPC.Server.send_reply(stream, %EventResponse{event_json: Jason.encode!(ev)})
        end)

      _ ->
        :ok
    end

    stream
  end
end

defmodule MirrorNeuron.Grpc.Endpoint do
  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)

  run(MirrorNeuron.Grpc.JobServer)
  run(MirrorNeuron.Grpc.ClusterServer)
  run(MirrorNeuron.Grpc.ObservabilityServer)
end
