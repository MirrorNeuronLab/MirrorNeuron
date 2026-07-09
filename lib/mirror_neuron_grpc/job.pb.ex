defmodule Mirrorneuron.Job.V1.SubmitJobRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.SubmitJobRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V1.SubmitJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.SubmitJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:manifest_json, 1, type: :string, json_name: "manifestJson")

  field(:payloads, 2,
    repeated: true,
    type: Mirrorneuron.Job.V1.SubmitJobRequest.PayloadsEntry,
    map: true
  )

  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.SubmitJobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.SubmitJobResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:status, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.GetJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.GetJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.GetJobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.GetJobResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_json, 1, type: :string, json_name: "jobJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ListJobsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ListJobsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:limit, 1, type: :int32)
  field(:include_terminal, 2, type: :bool, json_name: "includeTerminal")
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ListJobsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ListJobsResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:jobs_json, 1, type: :string, json_name: "jobsJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.CancelJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CancelJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.CancelJobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CancelJobResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:status, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.PauseJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.PauseJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.PauseJobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.PauseJobResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:status, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ResumeJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ResumeJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ResumeJobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ResumeJobResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:status, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ExportJobBackupRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ExportJobBackupRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ExportJobBackupResponse.BundleFilesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ExportJobBackupResponse.BundleFilesEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V1.ExportJobBackupResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ExportJobBackupResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:backup_json, 1, type: :string, json_name: "backupJson")

  field(:bundle_files, 2,
    repeated: true,
    type: Mirrorneuron.Job.V1.ExportJobBackupResponse.BundleFilesEntry,
    json_name: "bundleFiles",
    map: true
  )

  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.RestoreJobBackupRequest.BundleFilesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.RestoreJobBackupRequest.BundleFilesEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V1.RestoreJobBackupRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.RestoreJobBackupRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:backup_json, 1, type: :string, json_name: "backupJson")

  field(:bundle_files, 2,
    repeated: true,
    type: Mirrorneuron.Job.V1.RestoreJobBackupRequest.BundleFilesEntry,
    json_name: "bundleFiles",
    map: true
  )

  field(:blueprint_id, 3, type: :string, json_name: "blueprintId")
  field(:run_id, 4, type: :string, json_name: "runId")
  field(:version, 5, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.RestoreJobBackupResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.RestoreJobBackupResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ClearJobsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ClearJobsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:admin_token, 1, type: :string, json_name: "adminToken")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ClearJobsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ClearJobsResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:cleared_count, 1, type: :int32, json_name: "clearedCount")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.DeployJobRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.DeployJobRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V1.DeployJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.DeployJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:manifest_json, 1, type: :string, json_name: "manifestJson")

  field(:payloads, 2,
    repeated: true,
    type: Mirrorneuron.Job.V1.DeployJobRequest.PayloadsEntry,
    map: true
  )

  field(:deployment_key, 3, type: :string, json_name: "deploymentKey")
  field(:update_policy_json, 4, type: :string, json_name: "updatePolicyJson")
  field(:wait, 5, type: :bool)
  field(:version, 6, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.UpdateDeploymentRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.UpdateDeploymentRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V1.UpdateDeploymentRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.UpdateDeploymentRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:deployment_key, 1, type: :string, json_name: "deploymentKey")
  field(:manifest_json, 2, type: :string, json_name: "manifestJson")

  field(:payloads, 3,
    repeated: true,
    type: Mirrorneuron.Job.V1.UpdateDeploymentRequest.PayloadsEntry,
    map: true
  )

  field(:update_policy_json, 4, type: :string, json_name: "updatePolicyJson")
  field(:wait, 5, type: :bool)
  field(:version, 6, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.GetDeploymentRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.GetDeploymentRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:id_or_key, 1, type: :string, json_name: "idOrKey")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ListDeploymentsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ListDeploymentsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:query_json, 1, type: :string, json_name: "queryJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.PromoteDeploymentRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.PromoteDeploymentRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:id_or_key, 1, type: :string, json_name: "idOrKey")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.RollbackDeploymentRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.RollbackDeploymentRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:id_or_key, 1, type: :string, json_name: "idOrKey")
  field(:version, 2, type: :string)
  field(:tag, 3, type: :string)
  field(:reason, 4, type: :string)
end

defmodule Mirrorneuron.Job.V1.DeploymentActionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.DeploymentActionRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:id_or_key, 1, type: :string, json_name: "idOrKey")
  field(:reason, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.DeploymentResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.DeploymentResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.CreateScheduleRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CreateScheduleRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V1.CreateScheduleRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CreateScheduleRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:manifest_json, 1, type: :string, json_name: "manifestJson")

  field(:payloads, 2,
    repeated: true,
    type: Mirrorneuron.Job.V1.CreateScheduleRequest.PayloadsEntry,
    map: true
  )

  field(:schedule_json, 3, type: :string, json_name: "scheduleJson")
  field(:source_json, 4, type: :string, json_name: "sourceJson")
  field(:version, 5, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ScheduleActionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ScheduleActionRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:schedule_id, 1, type: :string, json_name: "scheduleId")
  field(:attrs_json, 2, type: :string, json_name: "attrsJson")
  field(:reason, 3, type: :string)
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.GetScheduleRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.GetScheduleRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:schedule_id, 1, type: :string, json_name: "scheduleId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ListSchedulesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ListSchedulesRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:query_json, 1, type: :string, json_name: "queryJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.DispatchScheduleRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.DispatchScheduleRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:schedule_id, 1, type: :string, json_name: "scheduleId")
  field(:payload_json, 2, type: :string, json_name: "payloadJson")
  field(:reason, 3, type: :string)
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.EmitTriggerEventRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.EmitTriggerEventRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:event_type, 1, type: :string, json_name: "eventType")
  field(:payload_json, 2, type: :string, json_name: "payloadJson")
  field(:source, 3, type: :string)
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ListTriggerEventsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ListTriggerEventsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:limit, 1, type: :int32)
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.ScheduleResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ScheduleResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.JobService.Service do
  @moduledoc false

  use GRPC.Service, name: "mirrorneuron.job.v1.JobService", protoc_gen_elixir_version: "0.16.0"

  rpc(:SubmitJob, Mirrorneuron.Job.V1.SubmitJobRequest, Mirrorneuron.Job.V1.SubmitJobResponse)

  rpc(:GetJob, Mirrorneuron.Job.V1.GetJobRequest, Mirrorneuron.Job.V1.GetJobResponse)

  rpc(:ListJobs, Mirrorneuron.Job.V1.ListJobsRequest, Mirrorneuron.Job.V1.ListJobsResponse)

  rpc(:CancelJob, Mirrorneuron.Job.V1.CancelJobRequest, Mirrorneuron.Job.V1.CancelJobResponse)

  rpc(:PauseJob, Mirrorneuron.Job.V1.PauseJobRequest, Mirrorneuron.Job.V1.PauseJobResponse)

  rpc(:ResumeJob, Mirrorneuron.Job.V1.ResumeJobRequest, Mirrorneuron.Job.V1.ResumeJobResponse)

  rpc(
    :ExportJobBackup,
    Mirrorneuron.Job.V1.ExportJobBackupRequest,
    Mirrorneuron.Job.V1.ExportJobBackupResponse
  )

  rpc(
    :RestoreJobBackup,
    Mirrorneuron.Job.V1.RestoreJobBackupRequest,
    Mirrorneuron.Job.V1.RestoreJobBackupResponse
  )

  rpc(:ClearJobs, Mirrorneuron.Job.V1.ClearJobsRequest, Mirrorneuron.Job.V1.ClearJobsResponse)

  rpc(:DeployJob, Mirrorneuron.Job.V1.DeployJobRequest, Mirrorneuron.Job.V1.DeploymentResponse)

  rpc(
    :UpdateDeployment,
    Mirrorneuron.Job.V1.UpdateDeploymentRequest,
    Mirrorneuron.Job.V1.DeploymentResponse
  )

  rpc(
    :GetDeployment,
    Mirrorneuron.Job.V1.GetDeploymentRequest,
    Mirrorneuron.Job.V1.DeploymentResponse
  )

  rpc(
    :ListDeployments,
    Mirrorneuron.Job.V1.ListDeploymentsRequest,
    Mirrorneuron.Job.V1.DeploymentResponse
  )

  rpc(
    :PromoteDeployment,
    Mirrorneuron.Job.V1.PromoteDeploymentRequest,
    Mirrorneuron.Job.V1.DeploymentResponse
  )

  rpc(
    :RollbackDeployment,
    Mirrorneuron.Job.V1.RollbackDeploymentRequest,
    Mirrorneuron.Job.V1.DeploymentResponse
  )

  rpc(
    :PauseDeployment,
    Mirrorneuron.Job.V1.DeploymentActionRequest,
    Mirrorneuron.Job.V1.DeploymentResponse
  )

  rpc(
    :ResumeDeployment,
    Mirrorneuron.Job.V1.DeploymentActionRequest,
    Mirrorneuron.Job.V1.DeploymentResponse
  )

  rpc(
    :FailDeployment,
    Mirrorneuron.Job.V1.DeploymentActionRequest,
    Mirrorneuron.Job.V1.DeploymentResponse
  )

  rpc(
    :CreateSchedule,
    Mirrorneuron.Job.V1.CreateScheduleRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )

  rpc(
    :UpdateSchedule,
    Mirrorneuron.Job.V1.ScheduleActionRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )

  rpc(:GetSchedule, Mirrorneuron.Job.V1.GetScheduleRequest, Mirrorneuron.Job.V1.ScheduleResponse)

  rpc(
    :ListSchedules,
    Mirrorneuron.Job.V1.ListSchedulesRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )

  rpc(
    :PauseSchedule,
    Mirrorneuron.Job.V1.ScheduleActionRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )

  rpc(
    :ResumeSchedule,
    Mirrorneuron.Job.V1.ScheduleActionRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )

  rpc(
    :DeleteSchedule,
    Mirrorneuron.Job.V1.ScheduleActionRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )

  rpc(
    :DispatchSchedule,
    Mirrorneuron.Job.V1.DispatchScheduleRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )

  rpc(
    :EmitTriggerEvent,
    Mirrorneuron.Job.V1.EmitTriggerEventRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )

  rpc(
    :ListTriggerEvents,
    Mirrorneuron.Job.V1.ListTriggerEventsRequest,
    Mirrorneuron.Job.V1.ScheduleResponse
  )
end

defmodule Mirrorneuron.Job.V1.JobService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Job.V1.JobService.Service
end
