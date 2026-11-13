defmodule MirrorNeuron.Cluster.NodeDrainer do
  @moduledoc "Node drain, maintenance and drain-status entrypoints."

  alias MirrorNeuron.Cluster.NodeDrainer.Operations

  defdelegate drain_node(node), to: Operations
  defdelegate drain_node(node, opts), to: Operations
  defdelegate drain_job(job_id, node), to: Operations
  defdelegate drain_job(job_id, node, opts), to: Operations
  defdelegate cancel_node_drain(node), to: Operations
  defdelegate cancel_node_drain(node, opts), to: Operations
  defdelegate set_node_maintenance(node, enabled), to: Operations
  defdelegate set_node_maintenance(node, enabled, opts), to: Operations
  defdelegate node_drain_status(node), to: Operations
  defdelegate node_drain_status(node, opts), to: Operations
  defdelegate process_due_drains(), to: Operations
  defdelegate process_due_drains(opts), to: Operations
end
