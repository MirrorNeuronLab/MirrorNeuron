defmodule MirrorNeuron.Cluster.Reconciler do
  @moduledoc "Cluster recovery operations and durable evaluation entrypoints."

  alias MirrorNeuron.Cluster.Reconciler.Operations

  defdelegate reconcile_node(node), to: Operations
  defdelegate reconcile_node(node, opts), to: Operations
  defdelegate reconcile_job(job_id, node), to: Operations
  defdelegate reconcile_job(job_id, node, opts), to: Operations
  defdelegate reschedule_agents(job_id, agent_ids), to: Operations
  defdelegate reschedule_agents(job_id, agent_ids, opts), to: Operations
  defdelegate sweep_orphaned_jobs(), to: Operations
  defdelegate sweep_orphaned_jobs(owner_node), to: Operations
  defdelegate sweep_orphaned_jobs(owner_node, opts), to: Operations
  defdelegate process_due_evals(), to: Operations
  defdelegate process_due_evals(opts), to: Operations
  defdelegate wake_blocked_evals(), to: Operations
  defdelegate wake_blocked_evals(opts), to: Operations
end
