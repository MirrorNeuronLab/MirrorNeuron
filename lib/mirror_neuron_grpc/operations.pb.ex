defmodule Mirrorneuron.Operations.V1.StartOperationRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.operations.v1.StartOperationRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:kind, 1, type: :string)
  field(:options_json, 2, type: :string, json_name: "optionsJson")
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Operations.V1.StartOperationResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.operations.v1.StartOperationResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:operation_json, 1, type: :string, json_name: "operationJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Operations.V1.GetOperationRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.operations.v1.GetOperationRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:operation_id, 1, type: :string, json_name: "operationId")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Operations.V1.GetOperationResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.operations.v1.GetOperationResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:operation_json, 1, type: :string, json_name: "operationJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Operations.V1.StreamOperationEventsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.operations.v1.StreamOperationEventsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:operation_id, 1, type: :string, json_name: "operationId")
  field(:after_sequence, 2, type: :int64, json_name: "afterSequence")
  field(:follow, 3, type: :bool)
  field(:heartbeat_interval_ms, 4, type: :int32, json_name: "heartbeatIntervalMs")
  field(:version, 5, type: :uint32)
end

defmodule Mirrorneuron.Operations.V1.OperationEventResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.operations.v1.OperationEventResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:event_json, 1, type: :string, json_name: "eventJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Operations.V1.OperationsService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "mirrorneuron.operations.v1.OperationsService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(
    :StartOperation,
    Mirrorneuron.Operations.V1.StartOperationRequest,
    Mirrorneuron.Operations.V1.StartOperationResponse
  )

  rpc(
    :GetOperation,
    Mirrorneuron.Operations.V1.GetOperationRequest,
    Mirrorneuron.Operations.V1.GetOperationResponse
  )

  rpc(
    :StreamOperationEvents,
    Mirrorneuron.Operations.V1.StreamOperationEventsRequest,
    stream(Mirrorneuron.Operations.V1.OperationEventResponse)
  )
end

defmodule Mirrorneuron.Operations.V1.OperationsService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Operations.V1.OperationsService.Service
end
