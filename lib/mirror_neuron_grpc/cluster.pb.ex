defmodule Mirrorneuron.Cluster.V1.GetSystemSummaryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetSystemSummaryRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Mirrorneuron.Cluster.V1.GetSystemSummaryResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetSystemSummaryResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:summary_json, 1, type: :string, json_name: "summaryJson")
end

defmodule Mirrorneuron.Cluster.V1.GetResourceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetResourceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Mirrorneuron.Cluster.V1.GetResourceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetResourceResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:resource_json, 1, type: :string, json_name: "resourceJson")
end

defmodule Mirrorneuron.Cluster.V1.SetResourceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.SetResourceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:resource_json, 1, type: :string, json_name: "resourceJson")
end

defmodule Mirrorneuron.Cluster.V1.SetResourceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.SetResourceResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:resource_json, 1, type: :string, json_name: "resourceJson")
end

defmodule Mirrorneuron.Cluster.V1.RemoveNodeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.RemoveNodeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
end

defmodule Mirrorneuron.Cluster.V1.RemoveNodeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.RemoveNodeResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:status, 2, type: :string)
end

defmodule Mirrorneuron.Cluster.V1.ClusterService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "mirrorneuron.cluster.v1.ClusterService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(
    :GetSystemSummary,
    Mirrorneuron.Cluster.V1.GetSystemSummaryRequest,
    Mirrorneuron.Cluster.V1.GetSystemSummaryResponse
  )

  rpc(
    :GetResource,
    Mirrorneuron.Cluster.V1.GetResourceRequest,
    Mirrorneuron.Cluster.V1.GetResourceResponse
  )

  rpc(
    :SetResource,
    Mirrorneuron.Cluster.V1.SetResourceRequest,
    Mirrorneuron.Cluster.V1.SetResourceResponse
  )

  rpc(
    :RemoveNode,
    Mirrorneuron.Cluster.V1.RemoveNodeRequest,
    Mirrorneuron.Cluster.V1.RemoveNodeResponse
  )
end

defmodule Mirrorneuron.Cluster.V1.ClusterService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Cluster.V1.ClusterService.Service
end
