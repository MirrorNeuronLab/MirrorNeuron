defmodule Mirrorneuron.Job.V1.SubmitJobRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.SubmitJobRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :bytes
end

defmodule Mirrorneuron.Job.V1.SubmitJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.SubmitJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :manifest_json, 1, type: :string, json_name: "manifestJson"

  field :payloads, 2,
    repeated: true,
    type: Mirrorneuron.Job.V1.SubmitJobRequest.PayloadsEntry,
    map: true
end

defmodule Mirrorneuron.Job.V1.SubmitJobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.SubmitJobResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :job_id, 1, type: :string, json_name: "jobId"
  field :status, 2, type: :string
end

defmodule Mirrorneuron.Job.V1.GetJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.GetJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :job_id, 1, type: :string, json_name: "jobId"
end

defmodule Mirrorneuron.Job.V1.GetJobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.GetJobResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :job_json, 1, type: :string, json_name: "jobJson"
end

defmodule Mirrorneuron.Job.V1.ListJobsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ListJobsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :limit, 1, type: :int32
  field :include_terminal, 2, type: :bool, json_name: "includeTerminal"
end

defmodule Mirrorneuron.Job.V1.ListJobsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.ListJobsResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :jobs_json, 1, type: :string, json_name: "jobsJson"
end

defmodule Mirrorneuron.Job.V1.CancelJobRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CancelJobRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :job_id, 1, type: :string, json_name: "jobId"
end

defmodule Mirrorneuron.Job.V1.CancelJobResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.job.v1.CancelJobResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :job_id, 1, type: :string, json_name: "jobId"
  field :status, 2, type: :string
end

defmodule Mirrorneuron.Job.V1.JobService.Service do
  @moduledoc false

  use GRPC.Service, name: "mirrorneuron.job.v1.JobService", protoc_gen_elixir_version: "0.16.0"

  rpc :SubmitJob, Mirrorneuron.Job.V1.SubmitJobRequest, Mirrorneuron.Job.V1.SubmitJobResponse

  rpc :GetJob, Mirrorneuron.Job.V1.GetJobRequest, Mirrorneuron.Job.V1.GetJobResponse

  rpc :ListJobs, Mirrorneuron.Job.V1.ListJobsRequest, Mirrorneuron.Job.V1.ListJobsResponse

  rpc :CancelJob, Mirrorneuron.Job.V1.CancelJobRequest, Mirrorneuron.Job.V1.CancelJobResponse
end

defmodule Mirrorneuron.Job.V1.JobService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Job.V1.JobService.Service
end
