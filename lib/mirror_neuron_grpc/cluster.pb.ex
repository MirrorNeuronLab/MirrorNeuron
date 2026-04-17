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

  field :summary_json, 1, type: :string, json_name: "summaryJson"
end

defmodule Mirrorneuron.Cluster.V1.ClusterService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "mirrorneuron.cluster.v1.ClusterService",
    protoc_gen_elixir_version: "0.16.0"

  rpc :GetSystemSummary,
      Mirrorneuron.Cluster.V1.GetSystemSummaryRequest,
      Mirrorneuron.Cluster.V1.GetSystemSummaryResponse
end

defmodule Mirrorneuron.Cluster.V1.ClusterService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Cluster.V1.ClusterService.Service
end
