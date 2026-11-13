defmodule MirrorNeuron.Cluster.FederationRegistryTest.ReplayTest do
  use MirrorNeuron.FederationRegistryCase, async: false

  alias MirrorNeuron.Cluster.FederationClient
  alias MirrorNeuron.Cluster.FederationRegistry

  test "archive tombstones replay after a peer reconnects and remain on transport failure" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _tombstone} =
             FederationRegistry.queue_archive_tombstone("mirror_neuron@peer", "job-archive", 0)

    assert {:ok, [%{job_id: "job-archive", status: :pending}]} =
             FederationClient.replay_archive_tombstones("mirror_neuron@peer",
               call: fn _node, :archive_job, _request ->
                 raise GRPC.RPCError,
                   status: GRPC.Status.unavailable(),
                   message: "peer is offline"
               end
             )

    assert {:ok, [_pending]} = FederationRegistry.archive_tombstones("mirror_neuron@peer")

    assert {:ok, [%{job_id: "job-archive", status: :applied}]} =
             FederationClient.replay_archive_tombstones("mirror_neuron@peer",
               call: fn "mirror_neuron@peer", :archive_job, request ->
                 send(self(), {:archive_replayed, request})
                 :ok
               end
             )

    assert_receive {:archive_replayed, %{job_id: "job-archive", expected_revision: 0, version: 1}}
    assert {:ok, []} = FederationRegistry.archive_tombstones("mirror_neuron@peer")
  end

  test "delete tombstones replay after a peer reconnects and remove local projections" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _peer, _status} =
             FederationRegistry.put_projection("mirror_neuron@peer", [
               %{"job_id" => "job-delete", "status" => "active"}
             ])

    assert {:ok, _peer, _status} =
             FederationRegistry.put_run_projections("mirror_neuron@peer", [
               %{"job_id" => "job-delete", "run_id" => "run-delete", "status" => "completed"}
             ])

    assert {:ok, _tombstone} =
             FederationRegistry.queue_delete_tombstone("mirror_neuron@peer", "job-delete", 5)

    assert {:ok, [%{job_id: "job-delete", status: :pending}]} =
             FederationClient.replay_delete_tombstones("mirror_neuron@peer",
               call: fn _node, :delete_job, _request ->
                 raise GRPC.RPCError,
                   status: GRPC.Status.unavailable(),
                   message: "peer is offline"
               end
             )

    assert {:ok, [_pending]} = FederationRegistry.delete_tombstones("mirror_neuron@peer")

    assert {:ok, [%{job_id: "job-delete", status: :applied}]} =
             FederationClient.replay_delete_tombstones("mirror_neuron@peer",
               call: fn "mirror_neuron@peer", :delete_job, request ->
                 send(self(), {:delete_replayed, request})
                 :ok
               end
             )

    assert_receive {:delete_replayed,
                    %{job_id: "job-delete", expected_revision: 5, confirmed: true, version: 1}}

    assert {:ok, []} = FederationRegistry.delete_tombstones("mirror_neuron@peer")
    assert FederationRegistry.projection("job-delete") == nil
    assert FederationRegistry.projection("run-delete") == nil
  end

  test "a reachable archive rejection clears its tombstone instead of retrying later" do
    assert {:ok, _peer, _status} =
             FederationRegistry.register("mirror_neuron@peer", peer_info(), "scoped")

    assert {:ok, _tombstone} =
             FederationRegistry.queue_archive_tombstone("mirror_neuron@peer", "job-active", 0)

    assert {:ok, [%{job_id: "job-active", status: :rejected}]} =
             FederationClient.replay_archive_tombstones("mirror_neuron@peer",
               call: fn _node, :archive_job, _request ->
                 raise GRPC.RPCError,
                   status: GRPC.Status.failed_precondition(),
                   message: "job_has_active_runs"
               end
             )

    assert {:ok, []} = FederationRegistry.archive_tombstones("mirror_neuron@peer")
  end
end
