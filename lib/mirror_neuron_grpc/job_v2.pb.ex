defmodule Mirrorneuron.Job.V2.CreateJobRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.CreateJobRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V2.CreateJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.CreateJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:manifest_json, 1, type: :string, json_name: "manifestJson")

  field(:payloads, 2,
    repeated: true,
    type: Mirrorneuron.Job.V2.CreateJobRequest.PayloadsEntry,
    map: true
  )

  field(:job_id, 3, type: :string, json_name: "jobId")
  field(:resolved_configuration_json, 4, type: :string, json_name: "resolvedConfigurationJson")
  field(:storage_json, 5, type: :string, json_name: "storageJson")
  field(:version, 6, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.JobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.JobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.ListJobsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.ListJobsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:include_archived, 1, type: :bool, json_name: "includeArchived")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.UpdateJobRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.UpdateJobRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Job.V2.UpdateJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.UpdateJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:attrs_json, 2, type: :string, json_name: "attrsJson")
  field(:version, 3, type: :uint32)
  field(:manifest_json, 4, type: :string, json_name: "manifestJson")

  field(:payloads, 5,
    repeated: true,
    type: Mirrorneuron.Job.V2.UpdateJobRequest.PayloadsEntry,
    map: true
  )
end

defmodule Mirrorneuron.Job.V2.DeleteJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.DeleteJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:confirmed, 2, type: :bool)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.StartRunRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.StartRunRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:run_id, 2, type: :string, json_name: "runId")
  field(:inputs_json, 3, type: :string, json_name: "inputsJson")
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.RunRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.RunRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:run_id, 1, type: :string, json_name: "runId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.DeleteRunRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.DeleteRunRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:run_id, 1, type: :string, json_name: "runId")
  field(:confirmed, 2, type: :bool)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.SendRunInputRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.SendRunInputRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:run_id, 1, type: :string, json_name: "runId")
  field(:input_id, 2, type: :string, json_name: "inputId")
  field(:payload_json, 3, type: :string, json_name: "payloadJson")
  field(:idempotency_key, 4, type: :string, json_name: "idempotencyKey")
  field(:version, 5, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.CreateJobScheduleRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.CreateJobScheduleRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:job_id, 1, type: :string, json_name: "jobId")
  field(:schedule_json, 2, type: :string, json_name: "scheduleJson")
  field(:source_json, 3, type: :string, json_name: "sourceJson")
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.JsonResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v2.JsonResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Job.V2.JobService.Service do
  @moduledoc false

  use GRPC.Service, name: "mirrorneuron.job.v2.JobService", protoc_gen_elixir_version: "0.16.0"

  rpc(:CreateJob, Mirrorneuron.Job.V2.CreateJobRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:GetJob, Mirrorneuron.Job.V2.JobRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:ListJobs, Mirrorneuron.Job.V2.ListJobsRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:UpdateJob, Mirrorneuron.Job.V2.UpdateJobRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:ArchiveJob, Mirrorneuron.Job.V2.JobRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:ResetJobData, Mirrorneuron.Job.V2.JobRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:DeleteJob, Mirrorneuron.Job.V2.DeleteJobRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:StartRun, Mirrorneuron.Job.V2.StartRunRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:ListRuns, Mirrorneuron.Job.V2.JobRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:GetRun, Mirrorneuron.Job.V2.RunRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:PauseRun, Mirrorneuron.Job.V2.RunRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:ResumeRun, Mirrorneuron.Job.V2.RunRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:CancelRun, Mirrorneuron.Job.V2.RunRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(:DeleteRun, Mirrorneuron.Job.V2.DeleteRunRequest, Mirrorneuron.Job.V2.JsonResponse)

  rpc(
    :SendRunInput,
    Mirrorneuron.Job.V2.SendRunInputRequest,
    Mirrorneuron.Job.V2.JsonResponse
  )

  rpc(
    :CreateJobSchedule,
    Mirrorneuron.Job.V2.CreateJobScheduleRequest,
    Mirrorneuron.Job.V2.JsonResponse
  )
end

defmodule Mirrorneuron.Job.V2.JobService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Job.V2.JobService.Service
end
