defmodule MirrorNeuron.Cluster.FederatedNodeControl do
  @moduledoc "Node maintenance belongs to the node's own admission and persistence store."
  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry, NodeAdapter}

  alias Mirrorneuron.Cluster.V1.{
    DrainNodeRequest,
    CancelNodeDrainRequest,
    SetNodeMaintenanceRequest,
    GetNodeDrainStatusRequest
  }

  def remote?(name) do
    to_string(name) != to_string(NodeAdapter.self()) and
      match?({:ok, _}, FederationRegistry.fetch(name))
  end

  def drain(name, opts) do
    call(name, :drain_node, %DrainNodeRequest{
      node_name: to_string(name),
      reason: Keyword.get(opts, :reason) || "",
      dry_run: Keyword.get(opts, :dry_run, false),
      deadline_ms: Keyword.get(opts, :deadline_ms) || 0,
      ignore_system_jobs: Keyword.get(opts, :ignore_system_jobs, true),
      version: 1
    })
  end

  def cancel(name, opts) do
    call(name, :cancel_node_drain, %CancelNodeDrainRequest{
      node_name: to_string(name),
      reason: Keyword.get(opts, :reason) || "",
      mark_eligible: Keyword.get(opts, :mark_eligible, false),
      version: 1
    })
  end

  def maintenance(name, enabled, opts) do
    call(name, :set_node_maintenance, %SetNodeMaintenanceRequest{
      node_name: to_string(name),
      reason: Keyword.get(opts, :reason) || "",
      enabled: enabled,
      version: 1
    })
  end

  def status(name),
    do:
      call(name, :get_node_drain_status, %GetNodeDrainStatusRequest{
        node_name: to_string(name),
        version: 1
      })

  defp call(name, method, request) do
    response = FederationClient.call_cluster(name, method, request)
    Jason.decode(response.result_json)
  rescue
    error in GRPC.RPCError -> {:error, error}
  end
end
