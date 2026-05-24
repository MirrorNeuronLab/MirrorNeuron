defmodule MirrorNeuron.Grpc.JobServer do
  use GRPC.Server, service: Mirrorneuron.Job.V1.JobService.Service

  @admin_token_env "MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN"

  alias Mirrorneuron.Job.V1.{
    SubmitJobResponse,
    GetJobResponse,
    ListJobsResponse,
    CancelJobResponse,
    PauseJobResponse,
    ResumeJobResponse,
    ClearJobsResponse
  }

  def submit_job(request, _stream) do
    bundle_id = "bundle_#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), bundle_id)
    File.mkdir_p!(tmp_dir)

    File.write!(Path.join(tmp_dir, "manifest.json"), request.manifest_json)

    payloads_dir = Path.join(tmp_dir, "payloads")
    File.mkdir_p!(payloads_dir)

    with :ok <- write_payloads(payloads_dir, request.payloads),
         result <- MirrorNeuron.run_manifest(tmp_dir, await: false) do
      case result do
        {:ok, job_id} ->
          %SubmitJobResponse{job_id: job_id, status: "pending"}

        {:ok, job_id, _job} ->
          %SubmitJobResponse{job_id: job_id, status: "pending"}

        {:error, "resource_overloaded:" <> _ = reason} ->
          raise GRPC.RPCError, status: GRPC.Status.resource_exhausted(), message: reason

        {:error, "requirements_not_met:" <> _ = reason} ->
          raise GRPC.RPCError, status: GRPC.Status.failed_precondition(), message: reason

        {:error, "input_validation_failed:" <> _ = reason} ->
          raise GRPC.RPCError, status: GRPC.Status.invalid_argument(), message: reason

        {:error, reason} ->
          raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
      end
    else
      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: reason
    end
  end

  defp write_payloads(_payloads_dir, nil), do: :ok

  defp write_payloads(payloads_dir, payloads) do
    Enum.reduce_while(payloads, :ok, fn {path, content}, :ok ->
      case safe_payload_path(payloads_dir, path) do
        {:ok, full_path} ->
          File.mkdir_p!(Path.dirname(full_path))
          File.write!(full_path, content)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp safe_payload_path(payloads_dir, path) when is_binary(path) do
    payloads_root = Path.expand(payloads_dir)
    expanded = Path.expand(path, payloads_root)

    cond do
      path == "" or Path.type(path) != :relative or ".." in Path.split(path) ->
        {:error, "payload path must be relative and stay inside payloads/: #{inspect(path)}"}

      expanded == payloads_root or not String.starts_with?(expanded, payloads_root <> "/") ->
        {:error, "payload path must stay inside payloads/: #{inspect(path)}"}

      true ->
        {:ok, expanded}
    end
  end

  defp safe_payload_path(_payloads_dir, path) do
    {:error, "payload path must be a string: #{inspect(path)}"}
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

    case MirrorNeuron.Monitor.list_jobs(
           limit: limit,
           include_terminal: request.include_terminal,
           summary: :basic
         ) do
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

  def pause_job(request, stream) do
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

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

  def resume_job(request, stream) do
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

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

  def clear_jobs(request, _stream) do
    authorize_clear_jobs!(request)

    case MirrorNeuron.Monitor.clear_jobs() do
      {:ok, count} ->
        %ClearJobsResponse{cleared_count: count}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
    end
  end

  defp authorize_clear_jobs!(request) do
    configured_token = System.get_env(@admin_token_env)
    request_token = Map.get(request, :admin_token, "")

    unless valid_admin_token?(configured_token, request_token) do
      raise GRPC.RPCError,
        status: GRPC.Status.permission_denied(),
        message: "ClearJobs requires #{@admin_token_env}"
    end

    :ok
  end

  defp valid_admin_token?(configured_token, request_token)
       when is_binary(configured_token) and byte_size(configured_token) > 0 and
              is_binary(request_token) do
    configured_token == request_token
  end

  defp valid_admin_token?(_configured_token, _request_token), do: false
end

defmodule MirrorNeuron.Grpc.ClusterServer do
  use GRPC.Server, service: Mirrorneuron.Cluster.V1.ClusterService.Service

  alias Mirrorneuron.Cluster.V1.{
    GetResourceResponse,
    GetSystemSummaryResponse,
    ReconcileNodeResponse,
    RemoveNodeResponse,
    SetResourceResponse
  }

  def get_system_summary(_request, _stream) do
    case MirrorNeuron.Monitor.cluster_overview() do
      {:ok, overview} ->
        %GetSystemSummaryResponse{summary_json: Jason.encode!(overview)}

      _ ->
        %GetSystemSummaryResponse{summary_json: "{}"}
    end
  end

  def get_resource(_request, _stream) do
    %GetResourceResponse{resource_json: Jason.encode!(MirrorNeuron.resource_list())}
  end

  def set_resource(request, _stream) do
    with {:ok, attrs} <- Jason.decode(request.resource_json),
         {:ok, resource} <- MirrorNeuron.resource_set(attrs) do
      %SetResourceResponse{resource_json: Jason.encode!(resource)}
    else
      {:error, %Jason.DecodeError{} = error} ->
        raise GRPC.RPCError,
          status: :invalid_argument,
          message: "resource body must be valid JSON: #{Exception.message(error)}"

      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: to_string(reason)
    end
  end

  def remove_node(request, _stream) do
    case MirrorNeuron.remove_node(request.node_name) do
      {:ok, %{status: status}} ->
        %RemoveNodeResponse{node_name: request.node_name, status: status}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
    end
  end

  def reconcile_node(request, stream) do
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    opts =
      [
        reason: blank_to_nil(request.reason),
        dry_run: request.dry_run
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case MirrorNeuron.reconcile_node(request.node_name, opts) do
      {:ok, result} ->
        %ReconcileNodeResponse{result_json: Jason.encode!(result)}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
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
