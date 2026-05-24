defmodule MirrorNeuron.Grpc.NetworkOnly do
  @moduledoc false

  def enabled? do
    System.get_env("MN_NETWORK_ONLY", "false")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])
  end

  def reject_if_enabled!(operation) do
    if enabled?() do
      raise GRPC.RPCError,
        status: GRPC.Status.permission_denied(),
        message: "#{operation} is disabled while MN_NETWORK_ONLY=true"
    end

    :ok
  end
end

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
    ClearJobsResponse,
    DeploymentResponse,
    ScheduleResponse
  }

  def submit_job(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("SubmitJob")

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

        {:error, "service_requirements_not_met:" <> _ = reason} ->
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
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetJob")

    job_id = request.job_id

    case MirrorNeuron.job_details(job_id) do
      {:ok, details_map} ->
        %GetJobResponse{job_json: Jason.encode!(details_map)}

      _ ->
        %GetJobResponse{job_json: "{}"}
    end
  end

  def list_jobs(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListJobs")

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
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CancelJob")

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
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("PauseJob")
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
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ResumeJob")
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
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ClearJobs")
    authorize_clear_jobs!(request)

    case MirrorNeuron.Monitor.clear_jobs() do
      {:ok, count} ->
        %ClearJobsResponse{cleared_count: count}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
    end
  end

  def deploy_job(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DeployJob")

    with {:ok, tmp_dir} <- request_bundle_dir(request.manifest_json, request.payloads),
         {:ok, result} <-
           MirrorNeuron.deploy_manifest(tmp_dir,
             deployment_key: blank_to_nil(request.deployment_key),
             update_policy: decode_json_map(request.update_policy_json),
             wait: request.wait
           ) do
      %DeploymentResponse{result_json: Jason.encode!(result)}
    else
      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def update_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("UpdateDeployment")

    with {:ok, tmp_dir} <- request_bundle_dir(request.manifest_json, request.payloads),
         {:ok, result} <-
           MirrorNeuron.update_deployment(request.deployment_key, tmp_dir,
             update_policy: decode_json_map(request.update_policy_json),
             wait: request.wait
           ) do
      %DeploymentResponse{result_json: Jason.encode!(result)}
    else
      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def get_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetDeployment")

    case MirrorNeuron.get_deployment(request.id_or_key) do
      {:ok, result} -> %DeploymentResponse{result_json: Jason.encode!(result)}
      {:error, reason} -> raise GRPC.RPCError, status: :not_found, message: inspect(reason)
    end
  end

  def list_deployments(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListDeployments")

    opts =
      request.query_json
      |> decode_json_map()
      |> keyword_opts()

    case MirrorNeuron.list_deployments(opts) do
      {:ok, result} -> %DeploymentResponse{result_json: Jason.encode!(%{"data" => result})}
      {:error, reason} -> raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  def promote_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("PromoteDeployment")
    deployment_action_response(MirrorNeuron.promote_deployment(request.id_or_key))
  end

  def rollback_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("RollbackDeployment")

    opts =
      []
      |> maybe_put_opt(:version, request.version)
      |> maybe_put_opt(:tag, request.tag)
      |> maybe_put_opt(:reason, request.reason)

    deployment_action_response(MirrorNeuron.rollback_deployment(request.id_or_key, opts))
  end

  def pause_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("PauseDeployment")

    deployment_action_response(
      MirrorNeuron.pause_deployment(request.id_or_key, reason: request.reason)
    )
  end

  def resume_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ResumeDeployment")

    deployment_action_response(
      MirrorNeuron.resume_deployment(request.id_or_key, reason: request.reason)
    )
  end

  def fail_deployment(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("FailDeployment")

    deployment_action_response(
      MirrorNeuron.fail_deployment(request.id_or_key, reason: request.reason)
    )
  end

  def create_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CreateSchedule")

    with {:ok, tmp_dir} <- request_bundle_dir(request.manifest_json, request.payloads),
         {:ok, schedule} <-
           MirrorNeuron.create_schedule(tmp_dir, decode_json_map(request.schedule_json),
             source: decode_json_map(request.source_json)
           ) do
      schedule_response(schedule)
    else
      {:error, reason} -> raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def update_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("UpdateSchedule")

    schedule_action_response(
      MirrorNeuron.update_schedule(request.schedule_id, decode_json_map(request.attrs_json))
    )
  end

  def get_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetSchedule")
    schedule_action_response(MirrorNeuron.get_schedule(request.schedule_id))
  end

  def list_schedules(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListSchedules")

    opts =
      request.query_json
      |> decode_json_map()
      |> schedule_keyword_opts()

    case MirrorNeuron.list_schedules(opts) do
      {:ok, schedules} -> schedule_response(%{"data" => schedules})
      {:error, reason} -> raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  def pause_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("PauseSchedule")

    schedule_action_response(
      MirrorNeuron.pause_schedule(request.schedule_id, reason: request.reason)
    )
  end

  def resume_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ResumeSchedule")

    schedule_action_response(
      MirrorNeuron.resume_schedule(request.schedule_id, reason: request.reason)
    )
  end

  def delete_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DeleteSchedule")

    case MirrorNeuron.delete_schedule(request.schedule_id, reason: request.reason) do
      :ok -> schedule_response(%{"schedule_id" => request.schedule_id, "status" => "deleted"})
      {:ok, result} -> schedule_response(result)
      {:error, reason} -> raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def dispatch_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DispatchSchedule")

    schedule_action_response(
      MirrorNeuron.dispatch_schedule(request.schedule_id, decode_json_map(request.payload_json),
        reason: request.reason
      )
    )
  end

  def emit_trigger_event(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("EmitTriggerEvent")

    schedule_action_response(
      MirrorNeuron.emit_trigger_event(request.event_type, decode_json_map(request.payload_json),
        source: blank_to_nil(request.source) || "api"
      )
    )
  end

  def list_trigger_events(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListTriggerEvents")

    case MirrorNeuron.list_trigger_events(limit: request.limit) do
      {:ok, events} -> schedule_response(%{"data" => events})
      {:error, reason} -> raise GRPC.RPCError, status: :internal, message: inspect(reason)
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

  defp request_bundle_dir(manifest_json, payloads) do
    bundle_id = "bundle_#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), bundle_id)
    payloads_dir = Path.join(tmp_dir, "payloads")

    File.mkdir_p!(payloads_dir)
    File.write!(Path.join(tmp_dir, "manifest.json"), manifest_json)

    with :ok <- write_payloads(payloads_dir, payloads) do
      {:ok, tmp_dir}
    end
  end

  defp deployment_action_response({:ok, result}) do
    %DeploymentResponse{result_json: Jason.encode!(result)}
  end

  defp deployment_action_response({:error, reason}) do
    raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
  end

  defp schedule_action_response({:ok, result}), do: schedule_response(result)

  defp schedule_action_response({:error, reason}) do
    raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
  end

  defp schedule_response(result), do: %ScheduleResponse{result_json: Jason.encode!(result)}

  defp decode_json_map(nil), do: %{}
  defp decode_json_map(""), do: %{}

  defp decode_json_map(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp keyword_opts(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {"deployment_key", value} -> [deployment_key: value]
      {"status", value} -> [status: value]
      _other -> []
    end)
  end

  defp schedule_keyword_opts(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {"kind", value} -> [kind: value]
      {"status", value} -> [status: value]
      {"enabled", value} when is_boolean(value) -> [enabled: value]
      _other -> []
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

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
    AddNodeResponse,
    CancelNodeDrainResponse,
    CheckServicesResponse,
    DrainNodeResponse,
    GetNodeDrainStatusResponse,
    GetResourceResponse,
    GetSystemSummaryResponse,
    ListServicesResponse,
    NetworkHandshakeResponse,
    ReconcileNodeResponse,
    RemoveNodeResponse,
    ResolveServiceResponse,
    SetNodeMaintenanceResponse,
    SetResourceResponse
  }

  def network_handshake(request, _stream) do
    authorize_network_join!(Map.get(request, :token, ""))

    %NetworkHandshakeResponse{
      node_name: to_string(Node.self()),
      runtime_mode:
        if(MirrorNeuron.Grpc.NetworkOnly.enabled?(), do: "network_only", else: "full"),
      grpc_host: advertised_host(),
      grpc_port: env_integer("MN_GRPC_PORT", 50_051),
      dist_port: env_integer("MN_DIST_PORT", 4_370),
      redis_host: redis_host(),
      redis_port: redis_port(),
      redis_url: redis_url(),
      cluster_nodes: System.get_env("MN_CLUSTER_NODES", ""),
      network_only: MirrorNeuron.Grpc.NetworkOnly.enabled?()
    }
  end

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
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("SetResource")

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

  def add_node(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("AddNode")
    maybe_set_remote_cookie(request.node_name, Map.get(request, :token, ""))

    case MirrorNeuron.add_node(request.node_name) do
      {:ok, %{status: status}} ->
        %AddNodeResponse{node_name: request.node_name, status: status}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
    end
  end

  def remove_node(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("RemoveNode")

    case MirrorNeuron.remove_node(request.node_name) do
      {:ok, %{status: status}} ->
        %RemoveNodeResponse{node_name: request.node_name, status: status}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
    end
  end

  def reconcile_node(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ReconcileNode")
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

  def drain_node(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DrainNode")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    opts =
      [
        reason: blank_to_nil(request.reason),
        dry_run: request.dry_run,
        deadline_ms: if(request.deadline_ms > 0, do: request.deadline_ms, else: nil),
        ignore_system_jobs: request.ignore_system_jobs
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case MirrorNeuron.drain_node(request.node_name, opts) do
      {:ok, result} ->
        %DrainNodeResponse{result_json: Jason.encode!(result)}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def cancel_node_drain(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CancelNodeDrain")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    opts =
      [
        reason: blank_to_nil(request.reason),
        mark_eligible: request.mark_eligible
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case MirrorNeuron.cancel_node_drain(request.node_name, opts) do
      {:ok, result} ->
        %CancelNodeDrainResponse{result_json: Jason.encode!(result)}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def set_node_maintenance(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("SetNodeMaintenance")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    opts =
      [reason: blank_to_nil(request.reason)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case MirrorNeuron.set_node_maintenance(request.node_name, request.enabled, opts) do
      {:ok, result} ->
        %SetNodeMaintenanceResponse{result_json: Jason.encode!(result)}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def get_node_drain_status(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetNodeDrainStatus")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    case MirrorNeuron.node_drain_status(request.node_name) do
      {:ok, result} ->
        %GetNodeDrainStatusResponse{result_json: Jason.encode!(result)}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def list_services(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListServices")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    opts = query_opts(request.query_json)

    case MirrorNeuron.list_services(opts) do
      {:ok, services} ->
        %ListServicesResponse{result_json: Jason.encode!(%{"services" => services})}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def resolve_service(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ResolveService")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    opts = query_opts(request.query_json)

    case MirrorNeuron.resolve_service(request.name, opts) do
      {:ok, services} ->
        %ResolveServiceResponse{result_json: Jason.encode!(%{"services" => services})}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def check_services(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CheckServices")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    with {:ok, services} <- decode_json(request.services_json, []) do
      case MirrorNeuron.check_services(services) do
        {:ok, result} ->
          %CheckServicesResponse{result_json: Jason.encode!(result)}

        {:error, reason} ->
          raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
      end
    else
      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.invalid_argument(), message: reason
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp query_opts(json) do
    json
    |> decode_json(%{})
    |> case do
      {:ok, query} when is_map(query) ->
        query
        |> Enum.flat_map(fn {key, value} ->
          case key do
            "name" -> [name: value]
            "node" -> [node: value]
            "job_id" -> [job_id: value]
            "agent_id" -> [agent_id: value]
            "status" -> [status: value]
            "tags" -> [tags: value]
            "passing_only" -> [passing_only: value]
            _ -> []
          end
        end)
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

      _ ->
        []
    end
  end

  defp decode_json("", default), do: {:ok, default}
  defp decode_json(nil, default), do: {:ok, default}

  defp decode_json(json, _default) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, "body must be valid JSON: #{Exception.message(error)}"}
    end
  end

  defp authorize_network_join!(request_token) do
    expected_token = System.get_env("MN_NETWORK_JOIN_TOKEN", "") |> String.trim()
    request_token = to_string(request_token || "") |> String.trim()

    unless expected_token != "" and secure_compare(request_token, expected_token) do
      raise GRPC.RPCError,
        status: GRPC.Status.unauthenticated(),
        message: "valid MN_NETWORK_JOIN_TOKEN is required"
    end

    :ok
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and
      :crypto.hash(:sha256, left) == :crypto.hash(:sha256, right)
  end

  defp secure_compare(_left, _right), do: false

  defp maybe_set_remote_cookie(node_name, token)
       when is_binary(node_name) and is_binary(token) and token != "" do
    cookie =
      :crypto.hash(:sha256, "mirror-neuron:cookie:#{token}")
      |> Base.encode16(case: :lower)
      |> String.to_atom()

    node_name
    |> String.to_atom()
    |> Node.set_cookie(cookie)

    :ok
  end

  defp maybe_set_remote_cookie(_node_name, _token), do: :ok

  defp advertised_host do
    System.get_env("MN_NETWORK_ADVERTISE_HOST") ||
      System.get_env("MN_CORE_HOST", "localhost")
  end

  defp redis_host do
    System.get_env("MN_NETWORK_REDIS_HOST") ||
      (redis_uri().host || advertised_host())
  end

  defp redis_port do
    env_integer("MN_NETWORK_REDIS_PORT", redis_uri().port || 6_379)
  end

  defp redis_url do
    uri = redis_uri()
    host = redis_host()
    port = redis_port()
    path = uri.path || "/0"
    scheme = uri.scheme || "redis"
    userinfo = if uri.userinfo, do: "#{uri.userinfo}@", else: ""

    "#{scheme}://#{userinfo}#{host}:#{port}#{path}"
  end

  defp redis_uri do
    "MN_REDIS_URL"
    |> System.get_env("redis://localhost:6379/0")
    |> URI.parse()
  end

  defp env_integer(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {value, ""} -> value
      _ -> default
    end
  end
end

defmodule MirrorNeuron.Grpc.ObservabilityServer do
  use GRPC.Server, service: Mirrorneuron.Observability.V1.ObservabilityService.Service

  alias Mirrorneuron.Observability.V1.EventResponse

  def stream_events(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("StreamEvents")

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
