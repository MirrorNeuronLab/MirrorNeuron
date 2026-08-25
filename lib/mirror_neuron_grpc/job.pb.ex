defmodule Mirrorneuron.Job.V1.CreateJobRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CreateJobRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V1.CreateJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CreateJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:manifest_json, 1, type: :string, json_name: "manifestJson")

  field(:payloads, 2,
    repeated: true,
    type: Mirrorneuron.Job.V1.CreateJobRequest.PayloadsEntry,
    map: true
  )

  field(:job_id, 3, type: :string, json_name: "jobId")
  field(:resolved_configuration_json, 4, type: :string, json_name: "resolvedConfigurationJson")
  field(:storage_json, 5, type: :string, json_name: "storageJson")
  field(:version, 6, type: :uint32)
  field(:idempotency_key, 7, type: :string, json_name: "idempotencyKey")
  field(:owner_node, 8, type: :string, json_name: "ownerNode")
end

defmodule Mirrorneuron.Job.V1.JobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.JobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:version, 2, type: :uint32)
  field(:expected_revision, 3, type: :uint64, json_name: "expectedRevision")
  field(:page_size, 4, type: :uint32, json_name: "pageSize")
  field(:page_token, 5, type: :string, json_name: "pageToken")
end

defmodule Mirrorneuron.Job.V1.ListJobsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ListJobsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:include_archived, 1, type: :bool, json_name: "includeArchived")
  field(:version, 2, type: :uint32)
  field(:page_size, 3, type: :uint32, json_name: "pageSize")
  field(:page_token, 4, type: :string, json_name: "pageToken")
  field(:local_only, 5, type: :bool, json_name: "localOnly")
end

defmodule Mirrorneuron.Job.V1.UpdateJobRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.UpdateJobRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V1.UpdateJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.UpdateJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:attrs_json, 2, type: :string, json_name: "attrsJson")
  field(:version, 3, type: :uint32)
  field(:manifest_json, 4, type: :string, json_name: "manifestJson")

  field(:payloads, 5,
    repeated: true,
    type: Mirrorneuron.Job.V1.UpdateJobRequest.PayloadsEntry,
    map: true
  )

  field(:expected_revision, 6, type: :uint64, json_name: "expectedRevision")
  field(:replace_existing_run, 7, type: :bool, json_name: "replaceExistingRun")
end

defmodule Mirrorneuron.Job.V1.DeleteJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.DeleteJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:confirmed, 2, type: :bool)
  field(:version, 3, type: :uint32)
  field(:expected_revision, 4, type: :uint64, json_name: "expectedRevision")
end

defmodule Mirrorneuron.Job.V1.StartRunRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.StartRunRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:run_id, 2, type: :string, json_name: "runId")
  field(:inputs_json, 3, type: :string, json_name: "inputsJson")
  field(:version, 4, type: :uint32)
  field(:idempotency_key, 5, type: :string, json_name: "idempotencyKey")
  field(:replace_existing_run, 6, type: :bool, json_name: "replaceExistingRun")
end

defmodule Mirrorneuron.Job.V1.RunRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.RunRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:run_id, 1, type: :string, json_name: "runId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.DeleteRunRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.DeleteRunRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:run_id, 1, type: :string, json_name: "runId")
  field(:confirmed, 2, type: :bool)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.SendRunInputRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.SendRunInputRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:run_id, 1, type: :string, json_name: "runId")
  field(:input_id, 2, type: :string, json_name: "inputId")
  field(:payload_json, 3, type: :string, json_name: "payloadJson")
  field(:idempotency_key, 4, type: :string, json_name: "idempotencyKey")
  field(:version, 5, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.CreateJobScheduleRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CreateJobScheduleRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:schedule_json, 2, type: :string, json_name: "scheduleJson")
  field(:source_json, 3, type: :string, json_name: "sourceJson")
  field(:version, 4, type: :uint32)
  field(:idempotency_key, 5, type: :string, json_name: "idempotencyKey")
end

defmodule Mirrorneuron.Job.V1.QueryJobResponseRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.QueryJobResponseRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:question, 2, type: :string)
  field(:conversation_id, 3, type: :string, json_name: "conversationId")
  field(:request_id, 4, type: :string, json_name: "requestId")
  field(:context_json, 5, type: :string, json_name: "contextJson")
  field(:version, 6, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.GetJobResponseTurnRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.GetJobResponseTurnRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:turn_id, 2, type: :string, json_name: "turnId")
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V1.JsonResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.JsonResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
  field(:revision, 3, type: :uint64)
  field(:next_page_token, 4, type: :string, json_name: "nextPageToken")
end

defmodule Mirrorneuron.Job.V1.JobService.Service do
  @moduledoc false

  use GRPC.Service, name: "mirrorneuron.job.v1.JobService", protoc_gen_elixir_version: "0.16.0"

  rpc(:CreateJob, Mirrorneuron.Job.V1.CreateJobRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:GetJob, Mirrorneuron.Job.V1.JobRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:ListJobs, Mirrorneuron.Job.V1.ListJobsRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:UpdateJob, Mirrorneuron.Job.V1.UpdateJobRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:ArchiveJob, Mirrorneuron.Job.V1.JobRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:ResetJobData, Mirrorneuron.Job.V1.JobRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:DeleteJob, Mirrorneuron.Job.V1.DeleteJobRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:StartRun, Mirrorneuron.Job.V1.StartRunRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:ListRuns, Mirrorneuron.Job.V1.JobRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:GetRun, Mirrorneuron.Job.V1.RunRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:PauseRun, Mirrorneuron.Job.V1.RunRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:ResumeRun, Mirrorneuron.Job.V1.RunRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:CancelRun, Mirrorneuron.Job.V1.RunRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:DeleteRun, Mirrorneuron.Job.V1.DeleteRunRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(:SendRunInput, Mirrorneuron.Job.V1.SendRunInputRequest, Mirrorneuron.Job.V1.JsonResponse)

  rpc(
    :CreateJobSchedule,
    Mirrorneuron.Job.V1.CreateJobScheduleRequest,
    Mirrorneuron.Job.V1.JsonResponse
  )

  rpc(
    :QueryJobResponse,
    Mirrorneuron.Job.V1.QueryJobResponseRequest,
    Mirrorneuron.Job.V1.JsonResponse
  )

  rpc(
    :GetJobResponseTurn,
    Mirrorneuron.Job.V1.GetJobResponseTurnRequest,
    Mirrorneuron.Job.V1.JsonResponse
  )
end

defmodule Mirrorneuron.Job.V1.JobService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Job.V1.JobService.Service
end
