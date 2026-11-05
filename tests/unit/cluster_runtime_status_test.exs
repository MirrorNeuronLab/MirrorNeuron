defmodule MirrorNeuron.Cluster.RuntimeStatusTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Cluster.RuntimeStatus
  alias Mirrorneuron.Cluster.V1.{GetNodeRuntimeStatusRequest, GetResourceResponse}

  defmodule Adapter do
    def self, do: :mirror_neuron@mini
    def list, do: [:mirror_neuron@direct]
  end

  defmodule States do
    def fetch(name) do
      send(self(), {:read_state, name})

      {:ok,
       %{
         "node" => name,
         "runtime_status" => %{"models" => %{"revision" => "v1", "status" => %{"models" => []}}}
       }}
    end
  end

  defmodule Registry do
    def fetch("mirror_neuron@spark"), do: {:ok, %{}}
    def fetch(_), do: {:error, :peer_not_found}
  end

  defmodule Peer do
    def call_cluster(name, command, request) do
      send(self(), {:forwarded, name, command, request})

      case Process.get(:peer_result) do
        %GRPC.RPCError{} = error -> raise error
        result -> %GetResourceResponse{resource_json: Jason.encode!(result), version: 1}
      end
    end
  end

  setup do
    Process.put(:peer_result, %{
      "name" => "mirror_neuron@spark",
      "runtime_status" => %{},
      "self" => true
    })

    %{
      opts: [
        node_adapter: Adapter,
        node_state: States,
        federation_registry: Registry,
        federation_client: Peer
      ]
    }
  end

  test "reads only the requested local or direct snapshot", %{opts: opts} do
    for name <- ["mirror_neuron@mini", "mirror_neuron@direct"] do
      assert %{"name" => ^name, "runtime_status" => %{"models" => %{}}} =
               RuntimeStatus.fetch(name, opts)

      assert_receive {:read_state, ^name}
    end

    refute_receive {:forwarded, _, _, _}
  end

  test "forwards a registered peer and verifies its identity", %{opts: opts} do
    assert %{"name" => "mirror_neuron@spark", "self" => false} =
             RuntimeStatus.fetch("mirror_neuron@spark", opts)

    assert_receive {:forwarded, "mirror_neuron@spark", :get_node_runtime_status,
                    %GetNodeRuntimeStatusRequest{node_name: "mirror_neuron@spark", version: 1}}

    refute_receive {:read_state, _}
  end

  test "a forwarded request can only read its destination", %{opts: opts} do
    assert %{"self" => true} =
             RuntimeStatus.fetch("mirror_neuron@mini", Keyword.put(opts, :hop, 1))

    error =
      assert_raise GRPC.RPCError, fn ->
        RuntimeStatus.fetch("mirror_neuron@spark", Keyword.put(opts, :hop, 1))
      end

    assert error.status == GRPC.Status.failed_precondition()
    refute_receive {:forwarded, _, _, _}
  end

  test "rejects unknown nodes and invalid peer responses", %{opts: opts} do
    error =
      assert_raise GRPC.RPCError, fn -> RuntimeStatus.fetch("mirror_neuron@unknown", opts) end

    assert error.status == GRPC.Status.not_found()

    for result <- [
          %{"name" => "mirror_neuron@wrong", "runtime_status" => %{}},
          %{"name" => "mirror_neuron@spark"}
        ] do
      Process.put(:peer_result, result)

      error =
        assert_raise GRPC.RPCError, fn -> RuntimeStatus.fetch("mirror_neuron@spark", opts) end

      assert error.status == GRPC.Status.failed_precondition()
    end
  end

  test "preserves peer authentication failures", %{opts: opts} do
    Process.put(
      :peer_result,
      GRPC.RPCError.exception(status: :unauthenticated, message: "rejected")
    )

    error = assert_raise GRPC.RPCError, fn -> RuntimeStatus.fetch("mirror_neuron@spark", opts) end
    assert error.status == GRPC.Status.unauthenticated()
  end

  test "restores an empty model list after Redis Lua serialization" do
    state = %{
      "node" => "mirror_neuron@mini",
      "runtime_status" => %{
        "models" => %{"revision" => "empty", "status" => %{"models" => %{}}}
      }
    }

    snapshot = RuntimeStatus.snapshot(state, "mirror_neuron@mini")
    assert get_in(snapshot, ["runtime_status", "models", "status", "models"]) == []
  end
end
