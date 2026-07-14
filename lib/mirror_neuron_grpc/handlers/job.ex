defmodule MirrorNeuron.Grpc.Handlers.Job do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Grpc.Handlers.Support

  alias Mirrorneuron.Job.V1.{
    SubmitJobResponse,
    GetJobResponse,
    ListJobsResponse,
    CancelJobResponse,
    PauseJobResponse,
    ResumeJobResponse,
    ExportJobBackupResponse,
    RestoreJobBackupResponse,
    ClearJobsResponse
  }

  def submit_job(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("SubmitJob")

    result =
      Support.with_request_bundle(request.manifest_json, request.payloads, fn tmp_dir ->
        case MirrorNeuron.run_manifest(tmp_dir, await: false) do
          {:ok, job_id} ->
            %SubmitJobResponse{job_id: job_id, status: "pending", version: @interface_version}

          {:ok, job_id, _job} ->
            %SubmitJobResponse{job_id: job_id, status: "pending", version: @interface_version}

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
      end)

    case result do
      %SubmitJobResponse{} = response ->
        response

      {:error, reason} ->
        raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def get_job(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetJob")

    job_id = request.job_id

    case MirrorNeuron.job_details(job_id, compact: true, event_limit: 10) do
      {:ok, details_map} ->
        %GetJobResponse{
          job_json: Support.versioned_json(details_map),
          version: @interface_version
        }

      _ ->
        %GetJobResponse{job_json: Support.versioned_json(%{}), version: @interface_version}
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
        %ListJobsResponse{
          jobs_json: Support.versioned_json(%{data: jobs}),
          version: @interface_version
        }

      _ ->
        %ListJobsResponse{
          jobs_json: Support.versioned_json(%{data: []}),
          version: @interface_version
        }
    end
  end

  def cancel_job(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CancelJob")

    job_id = request.job_id

    case MirrorNeuron.cancel(job_id) do
      {:error, reason} ->
        Support.raise_runtime_error!(reason)

      {:ok, status} ->
        %CancelJobResponse{job_id: job_id, status: status, version: @interface_version}

      _ ->
        %CancelJobResponse{job_id: job_id, status: "cancelled", version: @interface_version}
    end
  end

  def pause_job(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("PauseJob")

    job_id = request.job_id

    case MirrorNeuron.pause(job_id) do
      {:error, reason} ->
        Support.raise_runtime_error!(reason)

      {:ok, status} ->
        %PauseJobResponse{job_id: job_id, status: status, version: @interface_version}

      _ ->
        %PauseJobResponse{job_id: job_id, status: "paused", version: @interface_version}
    end
  end

  def resume_job(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ResumeJob")

    job_id = request.job_id

    case MirrorNeuron.resume(job_id) do
      {:error, reason} ->
        Support.raise_runtime_error!(reason)

      {:ok, status} ->
        %ResumeJobResponse{job_id: job_id, status: status, version: @interface_version}

      _ ->
        %ResumeJobResponse{job_id: job_id, status: "running", version: @interface_version}
    end
  end

  def export_job_backup(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ExportJobBackup")

    case MirrorNeuron.export_job_backup(request.job_id) do
      {:ok, backup, bundle_files} ->
        %ExportJobBackupResponse{
          backup_json: Support.versioned_json(backup),
          bundle_files: bundle_files,
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: Support.backup_error_status(reason), message: inspect(reason)
    end
  end

  def restore_job_backup(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("RestoreJobBackup")

    with {:ok, backup} <- Jason.decode(request.backup_json),
         {:ok, result} <-
           MirrorNeuron.restore_job_backup(backup, request.bundle_files,
             blueprint_id: Support.blank_to_nil(request.blueprint_id),
             run_id: Support.blank_to_nil(request.run_id)
           ) do
      %RestoreJobBackupResponse{
        result_json: Support.versioned_json(result),
        version: @interface_version
      }
    else
      {:error, %Jason.DecodeError{} = error} ->
        raise GRPC.RPCError,
          status: GRPC.Status.invalid_argument(),
          message: "backup_json must be valid JSON: #{Exception.message(error)}"

      {:error, reason} ->
        raise GRPC.RPCError, status: Support.backup_error_status(reason), message: inspect(reason)
    end
  end

  def clear_jobs(_request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ClearJobs")

    case MirrorNeuron.Monitor.clear_jobs() do
      {:ok, count} ->
        %ClearJobsResponse{cleared_count: count, version: @interface_version}

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: reason
    end
  end
end
