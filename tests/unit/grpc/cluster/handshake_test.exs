defmodule MirrorNeuron.Grpc.ClusterServerTest.HandshakeTest do
  use MirrorNeuron.GrpcClusterCase, async: false

  @identity_token_file_env "MN_GRPC_AUTH_TOKEN_FILE"

  @identity_token_env "MN_GRPC_AUTH_TOKEN"

  alias MirrorNeuron.Grpc.ClusterServer
  alias MirrorNeuron.Cluster.JoinClaim
  alias MirrorNeuron.Cluster.NodeState
  alias Mirrorneuron.Cluster.V1.NetworkHandshakeRequest

  test "network handshake accepts the configured join token", %{redis_url: redis_url} do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")
    System.put_env("MN_NETWORK_ADVERTISE_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_PORT", "6380")
    # Keep this pointed at the test Redis endpoint. The handshake reserves a
    # join claim and may reconnect its shared Redix client on a transient
    # failure, so a documentation-only hostname would make the test flaky.
    System.put_env("MN_REDIS_URL", redis_url)
    # The test Redis instance has no replica. Requiring one here makes the
    # join-claim write block and leaks that global setting into other tests.
    # Replica-wait validation is covered by Redis sentinel tests.
    System.put_env("MN_REDIS_WAIT_REPLICAS", "0")
    System.put_env("MN_REDIS_WAIT_TIMEOUT_MS", "1000")
    System.put_env("MN_GRPC_PORT", "50055")
    System.put_env("MN_DIST_PORT", "4500")
    System.put_env("MN_CLUSTER_NODES", "mirror_neuron@192.168.4.10")
    System.put_env("MN_NODE_RUNTIME_MODELS", "nemotron3")
    System.put_env("MN_HOST_SHARED_STORAGE_ROOT", "/mnt/mn-shared")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", "/root/.mn/shared")
    System.put_env(@identity_token_env, "primary-auth-token")

    response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          version: 1,
          token: "join-secret",
          node_name: "mirror_neuron@192.168.4.20"
        },
        nil
      )

    assert response.network_only
    assert response.runtime_mode == "network_only"
    assert response.grpc_host == "192.168.4.10"
    assert response.grpc_port == 50_055
    assert response.dist_port == 4_500
    assert response.redis_host == ""
    assert response.redis_port == 0
    assert response.redis_url == ""
    assert response.cluster_nodes == ""

    assert response.grpc_auth_token ==
             MirrorNeuron.Grpc.Tokens.peer_token("mirror_neuron@192.168.4.20")

    node_info = Jason.decode!(response.node_info_json)
    assert node_info["node_name"] == "mirror_neuron@test"
    assert node_info["host_shared_storage_root"] == "/mnt/mn-shared"
    assert node_info["runtime_shared_storage_root"] == "/root/.mn/shared"
    assert node_info["redis_ha"]["wait_replicas"] == 0
    assert node_info["redis_ha"]["wait_timeout_ms"] == 1000
    assert node_info["runtime_models"] == ["nemotron3"]
    assert is_binary(node_info["display_name"])
    assert is_integer(node_info["gpu_count"])
    assert is_map(node_info["hardware"])
    assert is_list(node_info["hardware"]["capabilities"])
  end

  test "network handshake never advertises standalone Redis URLs" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")
    System.put_env("MN_NETWORK_ADVERTISE_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_HOST", "192.168.4.10")
    System.put_env("MN_NETWORK_REDIS_PORT", "6380")
    System.put_env("MN_REDIS_URL", "redis://redis:6379/0")

    response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          version: 1,
          token: "join-secret",
          node_name: "mirror_neuron@192.168.4.20"
        },
        nil
      )

    assert response.redis_url == ""
  end

  test "network handshake returns a scoped peer token derived from the direct identity token" do
    auth_file = write_token_file("mn-auth-token", "file-auth-token")

    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")
    System.put_env(@identity_token_env, "stale-auth-token")
    System.put_env(@identity_token_file_env, auth_file)

    response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          version: 1,
          token: "join-secret",
          node_name: "mirror_neuron@192.168.4.20"
        },
        nil
      )

    assert response.grpc_auth_token ==
             MirrorNeuron.Grpc.Tokens.peer_token("mirror_neuron@192.168.4.20")
  end

  test "network-only handshake does not record joining node metadata" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    joining_node = "mirror_neuron@10.0.0.90"

    _response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          version: 1,
          token: "join-secret",
          node_name: joining_node,
          node_info_json: Jason.encode!(%{"address" => "10.0.0.90"})
        },
        nil
      )

    assert {:error, _reason} = NodeState.fetch(joining_node)
  end

  test "network-only handshake keeps worker claimed by the first master" do
    System.put_env("MN_NETWORK_ONLY", "true")
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    owner_a = "mirror_neuron@10.0.0.11"
    owner_b = "mirror_neuron@10.0.0.12"

    response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{version: 1, token: "join-secret", node_name: owner_a},
        nil
      )

    assert response.network_only
    assert {:ok, %{"state" => "pending", "owner_node" => ^owner_a}} = JoinClaim.read()

    retry =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{version: 1, token: "join-secret", node_name: owner_a},
        nil
      )

    assert retry.network_only

    error =
      assert_raise GRPC.RPCError, fn ->
        ClusterServer.network_handshake(
          %NetworkHandshakeRequest{version: 1, token: "join-secret", node_name: owner_b},
          nil
        )
      end

    assert error.status == GRPC.Status.already_exists()
    assert Exception.message(error) =~ "already join a cluster"
  end

  test "network handshake records joining node metadata for scheduling" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    joining_node = "mirror_neuron@10.0.0.42"

    node_info = %{
      "node_name" => joining_node,
      "display_name" => "spark gb10",
      "address" => "10.0.0.42",
      "grpc_host" => "10.0.0.42",
      "node_role" => "runtime",
      "capabilities" => ["cuda", "nvidia", "nvidia-gb10"],
      "gpu_count" => 1,
      "hardware" => %{
        "gpu" => %{
          "vendor" => "NVIDIA",
          "model" => "NVIDIA GB10",
          "count" => 1,
          "memory_gb" => 128,
          "memory_source" => "shared_system_memory"
        }
      }
    }

    _response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          version: 1,
          token: "join-secret",
          node_name: joining_node,
          node_info_json: Jason.encode!(node_info)
        },
        nil
      )

    assert {:ok, state} = NodeState.fetch(joining_node)
    assert state["status"] == "joining"
    assert state["operator_disconnect"] == false
    assert state["scheduling_eligible"] == true
    assert state["display_name"] == "spark gb10"
    assert state["address"] == "10.0.0.42"
    assert state["grpc_host"] == "10.0.0.42"
    assert state["node_role"] == "runtime"
    assert state["capabilities"] == ["cuda", "nvidia", "nvidia-gb10"]
    assert state["gpu_count"] == 1
    assert get_in(state, ["hardware", "gpu", "model"]) == "NVIDIA GB10"
    assert get_in(state, ["hardware", "gpu", "memory_gb"]) == 128
    assert get_in(state, ["hardware", "gpu", "memory_source"]) == "shared_system_memory"
    assert NodeState.schedulable?(joining_node)
  end

  test "network handshake clears operator disconnect when a node rejoins with a new address" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    node_name = "mirror_neuron@10.0.0.42"

    assert {:ok, _state} =
             NodeState.mark(node_name, "disconnected", %{
               "operator_disconnect" => true,
               "scheduling_eligible" => false,
               "address" => "10.0.0.20",
               "grpc_host" => "10.0.0.20",
               "capabilities" => ["cpu"]
             })

    _response =
      ClusterServer.network_handshake(
        %NetworkHandshakeRequest{
          version: 1,
          token: "join-secret",
          node_name: node_name,
          node_info_json:
            Jason.encode!(%{
              "address" => "10.0.0.84",
              "grpc_host" => "10.0.0.84",
              "node_role" => "runtime",
              "capabilities" => ["cuda", "nvidia-gb10"],
              "gpu_count" => 1
            })
        },
        nil
      )

    assert {:ok, state} = NodeState.fetch(node_name)
    assert state["status"] == "joining"
    assert state["operator_disconnect"] == false
    assert state["scheduling_eligible"] == true
    assert state["address"] == "10.0.0.84"
    assert state["grpc_host"] == "10.0.0.84"
    assert state["capabilities"] == ["cuda", "nvidia-gb10"]
    assert state["gpu_count"] == 1
    assert NodeState.schedulable?(node_name)
  end

  test "network handshake refreshes cordoned node metadata without making it schedulable" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    for status <- ["maintenance", "draining"] do
      node_name = "mirror_neuron_#{status}@10.0.0.42"

      assert {:ok, _state} =
               NodeState.mark(node_name, status, %{
                 "scheduling_eligible" => false,
                 "address" => "10.0.0.20",
                 "grpc_host" => "10.0.0.20",
                 "capabilities" => ["cpu"]
               })

      _response =
        ClusterServer.network_handshake(
          %NetworkHandshakeRequest{
            version: 1,
            token: "join-secret",
            node_name: node_name,
            node_info_json:
              Jason.encode!(%{
                "address" => "10.0.0.84",
                "grpc_host" => "10.0.0.84",
                "node_role" => "runtime",
                "capabilities" => ["cuda", "nvidia-gb10"],
                "gpu_count" => 1
              })
          },
          nil
        )

      assert {:ok, state} = NodeState.fetch(node_name)
      assert state["status"] == status
      assert state["operator_disconnect"] == false
      assert state["address"] == "10.0.0.84"
      assert state["grpc_host"] == "10.0.0.84"
      assert state["capabilities"] == ["cuda", "nvidia-gb10"]
      assert state["gpu_count"] == 1
      refute NodeState.schedulable?(node_name)
    end
  end

  test "network handshake rejects a missing or wrong join token" do
    System.put_env("MN_NETWORK_JOIN_TOKEN", "join-secret")

    error =
      assert_raise GRPC.RPCError, fn ->
        ClusterServer.network_handshake(%NetworkHandshakeRequest{version: 1, token: "wrong"}, nil)
      end

    assert Exception.message(error) =~ "valid MN_NETWORK_JOIN_TOKEN is required"
  end
end
