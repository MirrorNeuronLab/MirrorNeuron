defmodule Mirrorneuron.Cluster.V1.NetworkHandshakeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.NetworkHandshakeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:token, 1, type: :string)
  field(:node_name, 2, type: :string, json_name: "nodeName")
  field(:node_info_json, 3, type: :string, json_name: "nodeInfoJson")
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.NetworkHandshakeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.NetworkHandshakeResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:runtime_mode, 2, type: :string, json_name: "runtimeMode")
  field(:grpc_host, 3, type: :string, json_name: "grpcHost")
  field(:grpc_port, 4, type: :int32, json_name: "grpcPort")
  field(:dist_port, 5, type: :int32, json_name: "distPort")
  field(:redis_host, 6, type: :string, json_name: "redisHost")
  field(:redis_port, 7, type: :int32, json_name: "redisPort")
  field(:redis_url, 8, type: :string, json_name: "redisUrl")
  field(:cluster_nodes, 9, type: :string, json_name: "clusterNodes")
  field(:network_only, 10, type: :bool, json_name: "networkOnly")
  field(:node_info_json, 11, type: :string, json_name: "nodeInfoJson")
  field(:grpc_auth_token, 12, type: :string, json_name: "grpcAuthToken")
  field(:version, 14, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.GetSystemSummaryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetSystemSummaryRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:version, 1, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.GetSystemSummaryResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetSystemSummaryResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:summary_json, 1, type: :string, json_name: "summaryJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.GetResourceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetResourceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:version, 1, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.GetResourceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetResourceResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:resource_json, 1, type: :string, json_name: "resourceJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.SetResourceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.SetResourceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:resource_json, 1, type: :string, json_name: "resourceJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.SetResourceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.SetResourceResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:resource_json, 1, type: :string, json_name: "resourceJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.PrepareDockerWorkerRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.PrepareDockerWorkerRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:manifest_json, 1, type: :string, json_name: "manifestJson")

  field(:payloads, 2,
    repeated: true,
    type: Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest.PayloadsEntry,
    map: true
  )

  field(:submission_id, 3, type: :string, json_name: "submissionId")
  field(:node_name, 4, type: :string, json_name: "nodeName")
  field(:version, 5, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.PrepareDockerWorkerResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.PrepareDockerWorkerResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.CleanupDockerWorkerRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.CleanupDockerWorkerRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:submission_id, 1, type: :string, json_name: "submissionId")
  field(:job_id, 2, type: :string, json_name: "jobId")
  field(:all_services, 3, type: :bool, json_name: "allServices")
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.CleanupDockerWorkerResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.CleanupDockerWorkerResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.PrepareDockerComposeRequest.PayloadsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.PrepareDockerComposeRequest.PayloadsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :bytes)
end

defmodule Mirrorneuron.Cluster.V1.PrepareDockerComposeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.PrepareDockerComposeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:manifest_json, 1, type: :string, json_name: "manifestJson")

  field(:payloads, 2,
    repeated: true,
    type: Mirrorneuron.Cluster.V1.PrepareDockerComposeRequest.PayloadsEntry,
    map: true
  )

  field(:submission_id, 3, type: :string, json_name: "submissionId")
  field(:node_name, 4, type: :string, json_name: "nodeName")
  field(:version, 5, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.PrepareDockerComposeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.PrepareDockerComposeResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.DockerComposeStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.DockerComposeStatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:project_json, 1, type: :string, json_name: "projectJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.DockerComposeStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.DockerComposeStatusResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.CleanupDockerComposeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.CleanupDockerComposeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:projects_json, 1, repeated: true, type: :string, json_name: "projectsJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.CleanupDockerComposeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.CleanupDockerComposeResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.AddNodeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.AddNodeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:token, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.AddNodeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.AddNodeResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:status, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.RemoveNodeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.RemoveNodeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.RemoveNodeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.RemoveNodeResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:status, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.RegisterFederatedPeerRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.RegisterFederatedPeerRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:peer_info_json, 2, type: :string, json_name: "peerInfoJson")
  field(:peer_auth_token, 3, type: :string, json_name: "peerAuthToken")
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.RegisterFederatedPeerResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.RegisterFederatedPeerResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:status, 2, type: :string)
  field(:peer_json, 3, type: :string, json_name: "peerJson")
  field(:version, 4, type: :uint32)
  field(:local_peer_auth_token, 5, type: :string, json_name: "localPeerAuthToken")
end

defmodule Mirrorneuron.Cluster.V1.GetFederatedPeerRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetFederatedPeerRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.GetFederatedPeerResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetFederatedPeerResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:peer_json, 1, type: :string, json_name: "peerJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.RemoveFederatedPeerRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.RemoveFederatedPeerRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.RemoveFederatedPeerResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.RemoveFederatedPeerResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:status, 2, type: :string)
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.ReconcileNodeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.ReconcileNodeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:reason, 2, type: :string)
  field(:dry_run, 3, type: :bool, json_name: "dryRun")
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.ReconcileNodeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.ReconcileNodeResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.DrainNodeRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.DrainNodeRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:reason, 2, type: :string)
  field(:dry_run, 3, type: :bool, json_name: "dryRun")
  field(:deadline_ms, 4, type: :int64, json_name: "deadlineMs")
  field(:ignore_system_jobs, 5, type: :bool, json_name: "ignoreSystemJobs")
  field(:wait, 6, type: :bool)
  field(:version, 7, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.DrainNodeResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.DrainNodeResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.CancelNodeDrainRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.CancelNodeDrainRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:reason, 2, type: :string)
  field(:mark_eligible, 3, type: :bool, json_name: "markEligible")
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.CancelNodeDrainResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.CancelNodeDrainResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.SetNodeMaintenanceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.SetNodeMaintenanceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:enabled, 2, type: :bool)
  field(:reason, 3, type: :string)
  field(:version, 4, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.SetNodeMaintenanceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.SetNodeMaintenanceResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.GetNodeDrainStatusRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetNodeDrainStatusRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:node_name, 1, type: :string, json_name: "nodeName")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.GetNodeDrainStatusResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.GetNodeDrainStatusResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.ListServicesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.ListServicesRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:query_json, 1, type: :string, json_name: "queryJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.ListServicesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.ListServicesResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.ResolveServiceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.ResolveServiceRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:query_json, 2, type: :string, json_name: "queryJson")
  field(:version, 3, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.ResolveServiceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.ResolveServiceResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.CheckServicesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.CheckServicesRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:services_json, 1, type: :string, json_name: "servicesJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.CheckServicesResponse do
  @moduledoc false

  use Protobuf,
    full_name: "mirrorneuron.cluster.v1.CheckServicesResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:result_json, 1, type: :string, json_name: "resultJson")
  field(:version, 2, type: :uint32)
end

defmodule Mirrorneuron.Cluster.V1.ClusterService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "mirrorneuron.cluster.v1.ClusterService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(
    :NetworkHandshake,
    Mirrorneuron.Cluster.V1.NetworkHandshakeRequest,
    Mirrorneuron.Cluster.V1.NetworkHandshakeResponse
  )

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
    :GetRuntimeStatuses,
    Mirrorneuron.Cluster.V1.GetResourceRequest,
    Mirrorneuron.Cluster.V1.GetResourceResponse
  )

  rpc(
    :PublishRuntimeStatus,
    Mirrorneuron.Cluster.V1.SetResourceRequest,
    Mirrorneuron.Cluster.V1.SetResourceResponse
  )

  rpc(
    :AckRuntimeStatusEvents,
    Mirrorneuron.Cluster.V1.SetResourceRequest,
    Mirrorneuron.Cluster.V1.SetResourceResponse
  )

  rpc(:AddNode, Mirrorneuron.Cluster.V1.AddNodeRequest, Mirrorneuron.Cluster.V1.AddNodeResponse)

  rpc(
    :RemoveNode,
    Mirrorneuron.Cluster.V1.RemoveNodeRequest,
    Mirrorneuron.Cluster.V1.RemoveNodeResponse
  )

  rpc(
    :RegisterFederatedPeer,
    Mirrorneuron.Cluster.V1.RegisterFederatedPeerRequest,
    Mirrorneuron.Cluster.V1.RegisterFederatedPeerResponse
  )

  rpc(
    :GetFederatedPeer,
    Mirrorneuron.Cluster.V1.GetFederatedPeerRequest,
    Mirrorneuron.Cluster.V1.GetFederatedPeerResponse
  )

  rpc(
    :RemoveFederatedPeer,
    Mirrorneuron.Cluster.V1.RemoveFederatedPeerRequest,
    Mirrorneuron.Cluster.V1.RemoveFederatedPeerResponse
  )

  rpc(
    :ReconcileNode,
    Mirrorneuron.Cluster.V1.ReconcileNodeRequest,
    Mirrorneuron.Cluster.V1.ReconcileNodeResponse
  )

  rpc(
    :DrainNode,
    Mirrorneuron.Cluster.V1.DrainNodeRequest,
    Mirrorneuron.Cluster.V1.DrainNodeResponse
  )

  rpc(
    :CancelNodeDrain,
    Mirrorneuron.Cluster.V1.CancelNodeDrainRequest,
    Mirrorneuron.Cluster.V1.CancelNodeDrainResponse
  )

  rpc(
    :SetNodeMaintenance,
    Mirrorneuron.Cluster.V1.SetNodeMaintenanceRequest,
    Mirrorneuron.Cluster.V1.SetNodeMaintenanceResponse
  )

  rpc(
    :GetNodeDrainStatus,
    Mirrorneuron.Cluster.V1.GetNodeDrainStatusRequest,
    Mirrorneuron.Cluster.V1.GetNodeDrainStatusResponse
  )

  rpc(
    :ListServices,
    Mirrorneuron.Cluster.V1.ListServicesRequest,
    Mirrorneuron.Cluster.V1.ListServicesResponse
  )

  rpc(
    :ResolveService,
    Mirrorneuron.Cluster.V1.ResolveServiceRequest,
    Mirrorneuron.Cluster.V1.ResolveServiceResponse
  )

  rpc(
    :CheckServices,
    Mirrorneuron.Cluster.V1.CheckServicesRequest,
    Mirrorneuron.Cluster.V1.CheckServicesResponse
  )

  rpc(
    :SyncLiteLLMGateway,
    Mirrorneuron.Cluster.V1.SetResourceRequest,
    Mirrorneuron.Cluster.V1.SetResourceResponse
  )

  rpc(
    :RemoveLiteLLMGatewayRoute,
    Mirrorneuron.Cluster.V1.SetResourceRequest,
    Mirrorneuron.Cluster.V1.SetResourceResponse
  )

  rpc(
    :PrepareRuntimeModel,
    Mirrorneuron.Cluster.V1.SetResourceRequest,
    Mirrorneuron.Cluster.V1.SetResourceResponse
  )

  rpc(
    :PrepareDockerWorker,
    Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest,
    Mirrorneuron.Cluster.V1.PrepareDockerWorkerResponse
  )

  rpc(
    :CleanupDockerWorker,
    Mirrorneuron.Cluster.V1.CleanupDockerWorkerRequest,
    Mirrorneuron.Cluster.V1.CleanupDockerWorkerResponse
  )

  rpc(
    :PrepareDockerCompose,
    Mirrorneuron.Cluster.V1.PrepareDockerComposeRequest,
    Mirrorneuron.Cluster.V1.PrepareDockerComposeResponse
  )

  rpc(
    :GetDockerComposeStatus,
    Mirrorneuron.Cluster.V1.DockerComposeStatusRequest,
    Mirrorneuron.Cluster.V1.DockerComposeStatusResponse
  )

  rpc(
    :CleanupDockerCompose,
    Mirrorneuron.Cluster.V1.CleanupDockerComposeRequest,
    Mirrorneuron.Cluster.V1.CleanupDockerComposeResponse
  )
end

defmodule Mirrorneuron.Cluster.V1.ClusterService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Mirrorneuron.Cluster.V1.ClusterService.Service
end
