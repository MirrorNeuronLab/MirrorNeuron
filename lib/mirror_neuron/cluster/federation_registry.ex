defmodule MirrorNeuron.Cluster.FederationRegistry do
  @moduledoc "Federated peer identity, projections and durable tombstone API."

  alias MirrorNeuron.Cluster.FederationRegistry.Availability
  alias MirrorNeuron.Cluster.FederationRegistry.Peers
  alias MirrorNeuron.Cluster.FederationRegistry.Projections
  alias MirrorNeuron.Cluster.FederationRegistry.Tombstones

  defdelegate register(node_name, peer_info, peer_auth_token), to: Peers
  defdelegate fetch(node_name), to: Peers
  defdelegate public_fetch(node_name), to: Peers
  defdelegate list(), to: Peers
  defdelegate public_list(), to: Peers
  defdelegate ready?(), to: Peers
  defdelegate remove(node_name), to: Peers
  defdelegate queue_archive_tombstone(owner_node, job_id, expected_revision), to: Tombstones
  defdelegate queue_delete_tombstone(owner_node, job_id, expected_revision), to: Tombstones
  defdelegate archive_tombstones(owner_node), to: Tombstones
  defdelegate delete_tombstones(owner_node), to: Tombstones
  defdelegate clear_archive_tombstone(owner_node, job_id), to: Tombstones
  defdelegate clear_delete_tombstone(owner_node, job_id), to: Tombstones
  defdelegate mark_job_archived(owner_node, job_id), to: Projections
  defdelegate mark_job_deleted(owner_node, job_id), to: Projections
  defdelegate put_projection(node_name, summaries), to: Projections
  defdelegate replace_projections(node_name, summaries), to: Projections
  defdelegate put_run_projections(node_name, summaries), to: Projections
  defdelegate replace_run_projections(node_name, summaries), to: Projections
  defdelegate mark_projections_stale(node_name), to: Availability
  defdelegate mark_unavailable(node_name), to: Availability
  defdelegate projections(), to: Projections
  defdelegate run_projections(), to: Projections
  defdelegate remove_projection(node_name, resource_id), to: Projections
  defdelegate projection(resource_id), to: Projections
  defdelegate projection_owner(resource_id), to: Projections
  defdelegate mark_available(node_name), to: Availability
end
