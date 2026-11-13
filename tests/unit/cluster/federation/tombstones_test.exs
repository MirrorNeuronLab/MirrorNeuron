defmodule MirrorNeuron.Cluster.FederationRegistryTest.TombstonesTest do
  use MirrorNeuron.FederationRegistryCase, async: false

  alias MirrorNeuron.Cluster.FederationRegistry

  test "archive tombstones project a pending state until the owner confirms archival" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _peer, _status} =
             FederationRegistry.put_projection("mirror_neuron@peer", [
               %{"job_id" => "job-archive", "status" => "active"}
             ])

    assert {:ok, tombstone} =
             FederationRegistry.queue_archive_tombstone("mirror_neuron@peer", "job-archive", 0)

    assert tombstone["status"] == "pending"
    assert FederationRegistry.projection("job-archive")["status"] == "archive_pending"

    assert [%{"job_id" => "job-archive", "status" => "archive_pending"}] =
             FederationRegistry.projections()

    assert {:ok, [^tombstone]} = FederationRegistry.archive_tombstones("mirror_neuron@peer")

    assert {:ok, public_peer} = FederationRegistry.public_fetch("mirror_neuron@peer")
    refute Map.has_key?(public_peer, "archive_tombstones")

    assert :ok = FederationRegistry.clear_archive_tombstone("mirror_neuron@peer", "job-archive")
    assert [%{"job_id" => "job-archive"}] = FederationRegistry.projections()
  end

  test "a confirmed remote archive immediately updates its local projection" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _peer, _status} =
             FederationRegistry.put_projection("mirror_neuron@peer", [
               %{"job_id" => "job-archive", "status" => "active"}
             ])

    assert {:ok, %{"status" => "archived"}} =
             FederationRegistry.mark_job_archived("mirror_neuron@peer", "job-archive")

    assert [%{"job_id" => "job-archive", "status" => "archived"}] =
             FederationRegistry.projections()
  end

  test "delete tombstones hide stale jobs and their runs while retaining owner routing" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _peer, _status} =
             FederationRegistry.put_projection("mirror_neuron@peer", [
               %{"job_id" => "job-delete", "status" => "active"}
             ])

    assert {:ok, _peer, _status} =
             FederationRegistry.put_run_projections("mirror_neuron@peer", [
               %{"job_id" => "job-delete", "run_id" => "run-delete", "status" => "running"}
             ])

    assert {:ok, tombstone} =
             FederationRegistry.queue_delete_tombstone("mirror_neuron@peer", "job-delete", 4)

    assert tombstone["status"] == "pending"
    assert FederationRegistry.projection("job-delete")["status"] == "delete_pending"
    assert FederationRegistry.projection_owner("job-delete") == "mirror_neuron@peer"
    assert FederationRegistry.projections() == []
    assert FederationRegistry.run_projections() == []

    assert {:ok, [^tombstone]} = FederationRegistry.delete_tombstones("mirror_neuron@peer")

    assert {:ok, public_peer} = FederationRegistry.public_fetch("mirror_neuron@peer")
    refute Map.has_key?(public_peer, "delete_tombstones")
  end
end
