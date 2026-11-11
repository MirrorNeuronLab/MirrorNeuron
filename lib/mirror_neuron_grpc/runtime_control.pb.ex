defmodule Mirrorneuron.Runtime.V1.RuntimeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.runtime.v1.RuntimeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:version, 1, type: :uint32)
  field(:action, 2, type: :string)
  field(:arguments_json, 3, type: :string, json_name: "argumentsJson")
  field(:request_id, 4, type: :string, json_name: "requestId")
end

defmodule Mirrorneuron.Runtime.V1.RuntimeReply.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.runtime.v1.RuntimeReply.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Mirrorneuron.Runtime.V1.RuntimeReply do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.runtime.v1.RuntimeReply",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:version, 1, type: :uint32)
  field(:value_json, 2, type: :string, json_name: "valueJson")
  field(:status, 3, type: :uint32)

  field(:metadata, 4,
    repeated: true,
    type: Mirrorneuron.Runtime.V1.RuntimeReply.MetadataEntry,
    map: true
  )

  field(:error_json, 5, type: :string, json_name: "errorJson")
end

defmodule Mirrorneuron.Runtime.V1.RuntimeFrame do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.runtime.v1.RuntimeFrame",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:version, 1, type: :uint32)
  field(:kind, 2, type: :string)
  field(:data, 3, type: :bytes)
  field(:request, 4, type: Mirrorneuron.Runtime.V1.RuntimeRequest)
  field(:reply, 5, type: Mirrorneuron.Runtime.V1.RuntimeReply)
end

defmodule Mirrorneuron.Runtime.V1.RuntimeControlService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "mirrorneuron.runtime.v1.RuntimeControlService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(
    :GetCapabilities,
    Mirrorneuron.Runtime.V1.RuntimeRequest,
    Mirrorneuron.Runtime.V1.RuntimeReply
  )

  rpc(:Catalog, Mirrorneuron.Runtime.V1.RuntimeRequest, Mirrorneuron.Runtime.V1.RuntimeReply)

  rpc(:Prepare, Mirrorneuron.Runtime.V1.RuntimeRequest, Mirrorneuron.Runtime.V1.RuntimeReply)

  rpc(:Execute, Mirrorneuron.Runtime.V1.RuntimeRequest, Mirrorneuron.Runtime.V1.RuntimeReply)

  rpc(:Read, Mirrorneuron.Runtime.V1.RuntimeRequest, Mirrorneuron.Runtime.V1.RuntimeReply)

  rpc(
    :Events,
    Mirrorneuron.Runtime.V1.RuntimeRequest,
    stream(Mirrorneuron.Runtime.V1.RuntimeFrame)
  )

  rpc(
    :ReadFile,
    Mirrorneuron.Runtime.V1.RuntimeRequest,
    stream(Mirrorneuron.Runtime.V1.RuntimeFrame)
  )

  rpc(:Upload, stream(Mirrorneuron.Runtime.V1.RuntimeFrame), Mirrorneuron.Runtime.V1.RuntimeReply)

  rpc(
    :JobUi,
    stream(Mirrorneuron.Runtime.V1.RuntimeFrame),
    stream(Mirrorneuron.Runtime.V1.RuntimeFrame)
  )
end

defmodule Mirrorneuron.Runtime.V1.RuntimeControlService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Runtime.V1.RuntimeControlService.Service
end
