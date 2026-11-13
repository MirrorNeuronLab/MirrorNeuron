defmodule MirrorNeuron.Grpc.ClusterServerTest.StatusTest do
  use MirrorNeuron.GrpcClusterCase, async: false

  @identity_token_env "MN_GRPC_AUTH_TOKEN"

  alias MirrorNeuron.Grpc.ClusterServer
  alias MirrorNeuron.Cluster.NodeState
  alias Mirrorneuron.Cluster.V1.SetResourceRequest
  alias MirrorNeuron.GrpcClusterCase.ClusterNodeAdapterStub

  test "publish runtime status acknowledges the Redis-backed node snapshot" do
    System.put_env(@identity_token_env, "runtime-status-test")

    response =
      ClusterServer.publish_runtime_status(
        %SetResourceRequest{
          version: 1,
          resource_json:
            Jason.encode!(%{
              "domain" => "models",
              "revision" => "models-v1",
              "status" => %{
                "models" => [%{"id" => "nemotron3", "installed" => true}]
              }
            })
        },
        identity_stream("runtime-status-test")
      )

    assert %{
             "domain" => "models",
             "revision" => "models-v1",
             "status" => "accepted"
           } = Jason.decode!(response.resource_json)

    self_node = ClusterNodeAdapterStub.self() |> to_string()
    assert {:ok, state} = NodeState.fetch(self_node)

    assert get_in(state, ["runtime_status", "models", "status", "models"]) == [
             %{"id" => "nemotron3", "installed" => true}
           ]
  end

  test "get runtime statuses reads shared snapshots without probing peer nodes" do
    System.put_env(@identity_token_env, "runtime-status-test")
    remote_node = "mirror_neuron@spark"

    assert {:ok, _state} =
             NodeState.mark(remote_node, "healthy", %{
               "grpc_host" => "192.168.4.173",
               "runtime_status" => %{
                 "models" => %{
                   "revision" => "spark-v1",
                   "status" => %{"models" => [%{"id" => "nemotron3"}]}
                 }
               }
             })

    response =
      ClusterServer.get_runtime_statuses(
        %Mirrorneuron.Cluster.V1.GetResourceRequest{version: 1},
        identity_stream("runtime-status-test")
      )

    assert %{
             "nodes" => nodes,
             "events" => [event],
             "cluster_status" => cluster_status,
             "cluster_events" => [cluster_event],
             "cluster_event_ack" => %{"acked_count" => 2}
           } = Jason.decode!(response.resource_json)

    assert event["id"] == "1-0"
    assert cluster_event["domain"] == "schedules"

    assert get_in(cluster_status, ["schedules", "status", "records"]) == [
             %{"schedule_id" => "nightly"}
           ]

    assert_receive {:runtime_status_events_acked, ["1-1", "1-2"]}
    assert_receive {:cluster_runtime_status_events_acked, ["2-0", "2-1"]}
    spark = Enum.find(nodes, &(&1["name"] == remote_node))
    assert spark["grpc_host"] == "192.168.4.173"
    assert get_in(spark, ["runtime_status", "models", "revision"]) == "spark-v1"
    refute_receive {:rpc_call, _, _, _, _}
  end

  test "ack runtime status events acknowledges the local Redis Stream consumer group" do
    System.put_env(@identity_token_env, "runtime-status-test")

    response =
      ClusterServer.ack_runtime_status_events(
        %SetResourceRequest{
          version: 1,
          resource_json: Jason.encode!(%{"event_ids" => ["1-0", "2-0", "1-0"]})
        },
        identity_stream("runtime-status-test")
      )

    assert %{
             "status" => "acked",
             "event_ids" => ["1-0", "2-0"],
             "acked_count" => 2
           } = Jason.decode!(response.resource_json)

    assert_receive {:runtime_status_events_acked, ["1-0", "2-0"]}
  end

  test "authoritative node status requires identity and never acknowledges events" do
    System.put_env(@identity_token_env, "runtime-status-test")

    request = %Mirrorneuron.Cluster.V1.GetNodeRuntimeStatusRequest{
      node_name: "mirror_neuron@test",
      version: 1
    }

    assert_raise GRPC.RPCError, fn -> ClusterServer.get_node_runtime_status(request, nil) end
    assert {:ok, _} = NodeState.mark("mirror_neuron@test", "healthy", %{"runtime_status" => %{}})

    response =
      ClusterServer.get_node_runtime_status(request, identity_stream("runtime-status-test"))

    assert %{"name" => "mirror_neuron@test", "runtime_status" => %{}} =
             Jason.decode!(response.resource_json)

    refute_receive {:runtime_status_events_acked, _}
    refute_receive {:cluster_runtime_status_events_acked, _}
  end
end
