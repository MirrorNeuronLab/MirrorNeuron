defmodule MirrorNeuron.Cluster.FederationStatusTransportTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.{FederationClient, RuntimeStatus}
  alias Mirrorneuron.Cluster.V1.{GetNodeRuntimeStatusRequest, GetResourceResponse}

  defmodule Sender do
    def self, do: :mirror_neuron@mini
    def list, do: []
  end

  defmodule Owner do
    def self, do: :mirror_neuron@spark
    def list, do: []
  end

  defmodule Store do
    def fetch(name), do: {:ok, %{"node" => name, "runtime_status" => %{}}}
  end

  defmodule Server do
    use GRPC.Server, service: Mirrorneuron.Cluster.V1.ClusterService.Service

    def register_federated_peer(request, _stream) do
      send(:persistent_term.get({__MODULE__, :test}), {:peer_advertisement, request})

      %Mirrorneuron.Cluster.V1.RegisterFederatedPeerResponse{
        node_name: request.node_name,
        status: "already_registered",
        version: 1
      }
    end

    def get_node_runtime_status(request, stream) do
      MirrorNeuron.Grpc.CommandPolicy.enforce!(:cluster, :GetNodeRuntimeStatus, request, stream)

      snapshot =
        RuntimeStatus.fetch(request.node_name,
          node_adapter: Owner,
          node_state: Store,
          hop: MirrorNeuron.Grpc.Auth.federation_hop(stream)
        )

      %GetResourceResponse{resource_json: Jason.encode!(snapshot), version: 1}
    end
  end

  defmodule Endpoint do
    use GRPC.Endpoint
    run(Server)
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:grpc)
    monitor = Process.whereis(MirrorNeuron.Cluster.FederationMonitor)
    if monitor, do: :sys.suspend(monitor)
    env_keys = ["MN_HOME", "MN_GRPC_AUTH_TOKEN", "MN_RUNTIME_SHARED_STORAGE_ROOT"]
    previous_env = Map.take(System.get_env(), env_keys)
    previous_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)

    home =
      Path.join(System.tmp_dir!(), "mn-status-transport-#{System.unique_integer([:positive])}")

    System.put_env("MN_HOME", home)
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", Path.join(home, "shared"))
    System.put_env("MN_GRPC_AUTH_TOKEN", "spark-private-credential")
    Application.put_env(:mirror_neuron, :cluster_node_adapter, Sender)
    :persistent_term.put({Server, :test}, self())
    File.mkdir_p!(Path.join(home, "federation"))

    on_exit(fn ->
      for key <- env_keys do
        if value = previous_env[key],
          do: System.put_env(key, value),
          else: System.delete_env(key)
      end

      if previous_adapter,
        do: Application.put_env(:mirror_neuron, :cluster_node_adapter, previous_adapter),
        else: Application.delete_env(:mirror_neuron, :cluster_node_adapter)

      File.rm_rf!(home)
      :persistent_term.erase({Server, :test})
      MirrorNeuron.Cluster.Hardware.clear_snapshot()
      if monitor && Process.alive?(monitor), do: :sys.resume(monitor)
    end)

    {:ok, socket} = :gen_tcp.listen(0, active: false, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)

    start_supervised!(
      {GRPC.Server.Supervisor,
       endpoint: Endpoint, port: port, start_server: true, ip: {127, 0, 0, 1}}
    )

    # The application supervisor already owns the production channel pool.
    %{home: home, port: port}
  end

  test "refreshes hardware without a host identity file, even when job synchronization fails",
       ctx do
    register_fixture(ctx, MirrorNeuron.Grpc.Tokens.peer_token("mirror_neuron@mini"))
    refute File.exists?(Path.join(ctx.home, "node-identity.json"))

    for available <- [31_014, 119_240] do
      MirrorNeuron.Cluster.Hardware.update_snapshot(%{
        "memory" => %{"total_mb" => 124_607, "available_mb" => available},
        "gpu" => [%{"memory_total_mb" => 124_607, "memory_free_mb" => available}],
        "devices" => []
      })

      # This endpoint deliberately has no JobService. Hardware must already be
      # published before a separate job-inventory failure can stop the sync.
      assert {:error, %GRPC.RPCError{status: 13}} =
               FederationClient.sync_peer("mirror_neuron@spark")

      assert_receive {:peer_advertisement, request}
      assert request.node_name == "mirror_neuron@mini"
      info = Jason.decode!(request.peer_info_json)
      assert get_in(info, ["hardware", "memory", "available_mb"]) == available
      assert hd(info["hardware"]["gpu"])["memory_free_mb"] == available
      assert request.peer_auth_token == MirrorNeuron.Grpc.Tokens.peer_token("mirror_neuron@spark")
    end
  end

  test "production forwarding uses scoped identity, rejects local credentials, and keeps failures safe",
       ctx do
    request = %GetNodeRuntimeStatusRequest{node_name: "mirror_neuron@spark", version: 1}
    scoped = MirrorNeuron.Grpc.Tokens.peer_token("mirror_neuron@mini")
    register_fixture(ctx, scoped)

    response =
      FederationClient.call_cluster("mirror_neuron@spark", :get_node_runtime_status, request)

    assert %{"name" => "mirror_neuron@spark", "runtime_status" => %{}} =
             Jason.decode!(response.resource_json)

    refute response.resource_json =~ scoped

    # A second hop fails at the owner, using the production hop metadata.
    error =
      assert_raise GRPC.RPCError, fn ->
        FederationClient.call_cluster("mirror_neuron@spark", :get_node_runtime_status, %{
          request
          | node_name: "mirror_neuron@elsewhere"
        })
      end

    assert error.status == GRPC.Status.failed_precondition()

    for invalid <- [
          "mini-private-credential",
          MirrorNeuron.Grpc.Tokens.peer_token("mirror_neuron@other")
        ] do
      register_fixture(ctx, invalid)

      error =
        assert_raise GRPC.RPCError, fn ->
          FederationClient.call_cluster("mirror_neuron@spark", :get_node_runtime_status, request)
        end

      assert error.status == GRPC.Status.unauthenticated()
      refute Exception.message(error) =~ invalid
      assert error.message =~ "federation credentials were rejected"
    end

    register_fixture(ctx, scoped)

    assert %GetResourceResponse{} =
             FederationClient.call_cluster(
               "mirror_neuron@spark",
               :get_node_runtime_status,
               request
             )
  end

  defp register_fixture(ctx, credential) do
    peer = %{
      "node_name" => "mirror_neuron@spark",
      "grpc_host" => "127.0.0.1",
      "grpc_port" => ctx.port,
      "peer_auth_token" => credential
    }

    File.write!(
      Path.join([ctx.home, "federation", "peers.json"]),
      Jason.encode!(%{"peers" => %{"mirror_neuron@spark" => peer}})
    )
  end
end
