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

  @admin_token_env "MN_GRPC_ADMIN_TOKEN"

  alias Mirrorneuron.Job.V1.{
    SubmitJobResponse,
    GetJobResponse,
    ListJobsResponse,
    CancelJobResponse,
    PauseJobResponse,
    ResumeJobResponse,
    ExportJobBackupResponse,
    RestoreJobBackupResponse,
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

    case MirrorNeuron.job_details(job_id, compact: true, event_limit: 10) do
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

  def export_job_backup(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ExportJobBackup")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    case MirrorNeuron.export_job_backup(request.job_id) do
      {:ok, backup, bundle_files} ->
        %ExportJobBackupResponse{
          backup_json: Jason.encode!(backup),
          bundle_files: bundle_files
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: backup_error_status(reason), message: inspect(reason)
    end
  end

  def restore_job_backup(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("RestoreJobBackup")
    MirrorNeuron.Grpc.Auth.authorize_operator!(stream)

    with {:ok, backup} <- Jason.decode(request.backup_json),
         {:ok, result} <-
           MirrorNeuron.restore_job_backup(backup, request.bundle_files,
             blueprint_id: blank_to_nil(request.blueprint_id),
             run_id: blank_to_nil(request.run_id)
           ) do
      %RestoreJobBackupResponse{result_json: Jason.encode!(result)}
    else
      {:error, %Jason.DecodeError{} = error} ->
        raise GRPC.RPCError,
          status: GRPC.Status.invalid_argument(),
          message: "backup_json must be valid JSON: #{Exception.message(error)}"

      {:error, reason} ->
        raise GRPC.RPCError, status: backup_error_status(reason), message: inspect(reason)
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
    configured_token = configured_admin_token()
    request_token = Map.get(request, :admin_token, "")

    unless valid_admin_token?(configured_token, request_token) do
      raise GRPC.RPCError,
        status: GRPC.Status.permission_denied(),
        message: "ClearJobs requires #{@admin_token_env}"
    end

    :ok
  end

  defp configured_admin_token do
    MirrorNeuron.Grpc.Tokens.admin_token()
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

  defp backup_error_status(reason) do
    text = inspect(reason)

    cond do
      String.contains?(text, "not found") -> GRPC.Status.not_found()
      String.contains?(text, "must be paused") -> GRPC.Status.failed_precondition()
      true -> GRPC.Status.invalid_argument()
    end
  end

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
    MirrorNeuron.Grpc.Tokens.secure_compare(request_token, configured_token)
  end

  defp valid_admin_token?(_configured_token, _request_token), do: false
end

defmodule MirrorNeuron.Grpc.ClusterServer do
  use GRPC.Server, service: Mirrorneuron.Cluster.V1.ClusterService.Service

  alias MirrorNeuron.Cluster.NodeAdapter

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

    unless MirrorNeuron.Grpc.NetworkOnly.enabled?() do
      maybe_record_joining_node(request)
    end

    %NetworkHandshakeResponse{
      node_name: to_string(NodeAdapter.self()),
      runtime_mode:
        if(MirrorNeuron.Grpc.NetworkOnly.enabled?(), do: "network_only", else: "full"),
      grpc_host: advertised_host(),
      grpc_port: env_integer("MN_GRPC_PORT", 50_051),
      dist_port: env_integer("MN_DIST_PORT", 4_370),
      redis_host: redis_host(),
      redis_port: redis_port(),
      redis_url: redis_url(),
      cluster_nodes: System.get_env("MN_CLUSTER_NODES", ""),
      network_only: MirrorNeuron.Grpc.NetworkOnly.enabled?(),
      node_info_json: Jason.encode!(handshake_node_info()),
      grpc_auth_token: MirrorNeuron.Grpc.Tokens.auth_token() || "",
      grpc_admin_token: configured_admin_token() || ""
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
    token = Map.get(request, :token, "")
    maybe_set_remote_cookie(request.node_name, token)

    case MirrorNeuron.add_node(request.node_name) do
      {:ok, %{status: status}} ->
        sync_remote_cookie_with_cluster(request.node_name, token)
        %AddNodeResponse{node_name: request.node_name, status: status}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
    end
  end

  @doc false
  def set_peer_cookie(node_name, cookie_text)
      when is_binary(node_name) and is_binary(cookie_text) and
             node_name != "" and cookie_text != "" do
    with {:ok, node} <- MirrorNeuron.SafeAccess.node_name_to_atom(node_name),
         {:ok, cookie} <- MirrorNeuron.SafeAccess.nonempty_binary_to_atom(cookie_text) do
      NodeAdapter.set_cookie(node, cookie)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def connect_peer(node_name) when is_binary(node_name) and node_name != "" do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, node} ->
        NodeAdapter.connect(node)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def connect_peer(_node_name), do: :ok

  @doc false
  def disconnect_peer(node_name) when is_binary(node_name) and node_name != "" do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, node} ->
        NodeAdapter.disconnect(node)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def disconnect_peer(_node_name), do: :ok

  @doc false
  def disconnect_peers(node_names) when is_list(node_names) do
    Enum.each(node_names, &disconnect_peer/1)
    :ok
  end

  def remove_node(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("RemoveNode")
    disconnect_node_from_cluster(request.node_name)

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

  defp maybe_record_joining_node(request) do
    node_name = request |> Map.get(:node_name, "") |> to_string() |> String.trim()

    if node_name != "" do
      attrs =
        request
        |> Map.get(:node_info_json, "")
        |> decode_node_info()
        |> Map.put("operator_disconnect", false)
        |> Map.put("scheduling_eligible", true)

      MirrorNeuron.Cluster.NodeState.mark(node_name, handshake_node_status(node_name), attrs)
    end

    :ok
  end

  defp handshake_node_status(node_name) do
    case MirrorNeuron.Cluster.NodeState.fetch(node_name) do
      {:ok, %{"status" => status}} when status in ["healthy", "maintenance", "draining"] ->
        status

      _ ->
        "joining"
    end
  end

  defp decode_node_info(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> value
      _ -> %{}
    end
  end

  defp decode_node_info(_json), do: %{}

  defp handshake_node_info do
    hardware = MirrorNeuron.Cluster.Hardware.info()
    platform = Map.get(hardware, :platform, %{})
    cpu = Map.get(hardware, :cpu, %{})
    memory = Map.get(hardware, :memory, %{})
    gpu = Map.get(hardware, :gpu)

    %{
      "node_name" => to_string(NodeAdapter.self()),
      "node_role" => MirrorNeuron.Application.node_role(),
      "display_name" => map_value(platform, "display_name"),
      "hostname" => map_value(platform, "hostname"),
      "cpu_cores" => map_value(cpu, "logical_processors"),
      "cpu_model" => map_value(cpu, "model"),
      "gpu_count" => gpu_count(gpu),
      "gpu_model" => List.first(gpu_models(gpu)),
      "gpu_models" => gpu_models(gpu),
      "memory_gb" => memory_gb(memory)
    }
  end

  defp map_value(map, key) when is_map(map), do: MirrorNeuron.SafeAccess.map_get(map, key)

  defp map_value(_map, _key), do: nil

  defp gpu_count(gpu) when is_list(gpu), do: length(gpu)
  defp gpu_count(%{} = gpu), do: map_value(gpu, "count") || 0
  defp gpu_count(_gpu), do: 0

  defp gpu_models(gpus) when is_list(gpus) do
    gpus
    |> Enum.map(fn
      gpu when is_map(gpu) -> map_value(gpu, "model") || map_value(gpu, "name")
      gpu when is_binary(gpu) -> gpu
      _gpu -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or unknown_gpu?(&1)))
    |> Enum.uniq()
  end

  defp gpu_models(%{} = gpu), do: gpu_models([gpu])
  defp gpu_models(gpu) when is_binary(gpu), do: if(unknown_gpu?(gpu), do: [], else: [gpu])
  defp gpu_models(_gpu), do: []

  defp unknown_gpu?(gpu) do
    normalized = String.downcase(to_string(gpu || ""))

    Enum.any?(["unknown", "none", "unsupported", "not available"], fn marker ->
      String.contains?(normalized, marker)
    end)
  end

  defp memory_gb(memory) do
    case map_value(memory, "total_mb") do
      value when is_number(value) -> Float.round(value / 1024, 2)
      _ -> 0
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

  defp configured_admin_token do
    MirrorNeuron.Grpc.Tokens.admin_token()
  end

  defp secure_compare(left, right), do: MirrorNeuron.Grpc.Tokens.secure_compare(left, right)

  defp maybe_set_remote_cookie(node_name, token)
       when is_binary(node_name) and is_binary(token) and token != "" do
    with {:ok, node} <- MirrorNeuron.SafeAccess.node_name_to_atom(node_name),
         {:ok, cookie} <-
           cookie_from_token(token) |> MirrorNeuron.SafeAccess.nonempty_binary_to_atom() do
      NodeAdapter.set_cookie(node, cookie)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_set_remote_cookie(_node_name, _token), do: :ok

  defp sync_remote_cookie_with_cluster(node_name, token)
       when is_binary(node_name) and is_binary(token) and node_name != "" and token != "" do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, remote_node} ->
        cookie = cookie_from_token(token)

        NodeAdapter.list()
        |> Enum.reject(&(&1 == remote_node))
        |> Enum.each(fn peer ->
          _ = NodeAdapter.rpc_call(peer, __MODULE__, :set_peer_cookie, [node_name, cookie], 2_000)

          _ =
            NodeAdapter.rpc_call(
              remote_node,
              __MODULE__,
              :set_peer_cookie,
              [Atom.to_string(peer), cookie],
              2_000
            )
        end)

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp sync_remote_cookie_with_cluster(_node_name, _token), do: :ok

  defp disconnect_node_from_cluster(node_name) when is_binary(node_name) and node_name != "" do
    case MirrorNeuron.SafeAccess.node_name_to_atom(node_name) do
      {:ok, remote_node} ->
        connected_nodes = NodeAdapter.list()
        peer_nodes = Enum.reject(connected_nodes, &(&1 == remote_node))
        peer_names = Enum.map(peer_nodes, &Atom.to_string/1)

        if remote_node in connected_nodes do
          _ =
            NodeAdapter.rpc_call(remote_node, __MODULE__, :disconnect_peers, [peer_names], 2_000)
        end

        Enum.each(peer_nodes, fn peer ->
          _ = NodeAdapter.rpc_call(peer, __MODULE__, :disconnect_peer, [node_name], 2_000)
        end)

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp disconnect_node_from_cluster(_node_name), do: :ok

  defp cookie_from_token(token) do
    :crypto.hash(:sha256, "mirror-neuron:cookie:#{token}")
    |> Base.encode16(case: :lower)
  end

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
  alias MirrorNeuron.Runtime.EventBus

  def stream_events(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("StreamEvents")

    job_id = request.job_id
    follow? = Map.get(request, :follow, false)
    heartbeat_interval_ms = max(Map.get(request, :heartbeat_interval_ms, 0), 0)

    if follow? do
      EventBus.subscribe(job_id)
    end

    terminal? =
      case MirrorNeuron.events(job_id) do
        {:ok, events} ->
          Enum.each(events, fn ev ->
            GRPC.Server.send_reply(stream, %EventResponse{event_json: Jason.encode!(ev)})
          end)

          Enum.any?(events, &terminal_event?/1)

        _ ->
          false
      end

    if follow? and not terminal? do
      stream_live_events(job_id, stream, heartbeat_interval_ms)
    else
      stream
    end
  end

  defp stream_live_events(job_id, stream, heartbeat_interval_ms) do
    receive do
      {:mirror_neuron_event, event} ->
        GRPC.Server.send_reply(stream, %EventResponse{event_json: Jason.encode!(event)})

        if terminal_event?(event) do
          stream
        else
          stream_live_events(job_id, stream, heartbeat_interval_ms)
        end
    after
      heartbeat_timeout(heartbeat_interval_ms) ->
        if heartbeat_interval_ms > 0 do
          GRPC.Server.send_reply(stream, %EventResponse{
            event_json:
              Jason.encode!(%{
                type: "stream_heartbeat",
                job_id: job_id,
                timestamp: MirrorNeuron.Runtime.timestamp()
              })
          })
        end

        stream_live_events(job_id, stream, heartbeat_interval_ms)
    end
  rescue
    _ -> stream
  end

  defp heartbeat_timeout(interval) when is_integer(interval) and interval > 0, do: interval
  defp heartbeat_timeout(_interval), do: :infinity

  defp terminal_event?(event) when is_map(event) do
    event_type = Map.get(event, "type") || Map.get(event, :type)
    to_string(event_type) in ["job_completed", "job_failed", "job_cancelled"]
  end

  defp terminal_event?(_event), do: false
end

defmodule MirrorNeuron.Grpc.Endpoint do
  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)

  run(MirrorNeuron.Grpc.JobServer)
  run(MirrorNeuron.Grpc.ClusterServer)
  run(MirrorNeuron.Grpc.ObservabilityServer)
end
