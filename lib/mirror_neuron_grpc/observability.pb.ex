defmodule Mirrorneuron.Observability.V1.StreamEventsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.observability.v1.StreamEventsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :job_id, 1, type: :string, json_name: "jobId"
end

defmodule Mirrorneuron.Observability.V1.EventResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.observability.v1.EventResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :event_json, 1, type: :string, json_name: "eventJson"
end

defmodule Mirrorneuron.Observability.V1.ObservabilityService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "mirrorneuron.observability.v1.ObservabilityService",
    protoc_gen_elixir_version: "0.16.0"

  rpc :StreamEvents,
      Mirrorneuron.Observability.V1.StreamEventsRequest,
      stream(Mirrorneuron.Observability.V1.EventResponse)
end

defmodule Mirrorneuron.Observability.V1.ObservabilityService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Observability.V1.ObservabilityService.Service
end
