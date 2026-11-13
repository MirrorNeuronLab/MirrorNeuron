defmodule MirrorNeuron.ModelServices.RequestBoundaryTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.ModelServices

  setup do
    target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET")
    timeout = System.get_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS")
    keys = [:native_sdk_grpc_prepare_docker_worker_client, :native_sdk_grpc_sync_client]
    previous = Map.new(keys, &{&1, Application.get_env(:mirror_neuron, &1)})
    System.put_env("MN_NATIVE_SDK_GRPC_TARGET", "unused.test:1234")
    System.delete_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS")

    on_exit(fn ->
      for {key, value} <- [
            {"MN_NATIVE_SDK_GRPC_TARGET", target},
            {"MN_NATIVE_SDK_GRPC_TIMEOUT_MS", timeout}
          ] do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:mirror_neuron, key, value),
          else: Application.delete_env(:mirror_neuron, key)
      end
    end)

    :ok
  end

  test "structured native SDK transport errors return diagnostics without crashing" do
    Application.put_env(:mirror_neuron, :native_sdk_grpc_prepare_docker_worker_client, fn _,
                                                                                          _,
                                                                                          _ ->
      {:error, %{reason: :closed}}
    end)

    assert {:error, reason} =
             ModelServices.prepare_docker_worker(
               %Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest{}
             )

    assert reason =~ "closed"
  end

  test "JSON command responses reject non-object payloads and malformed JSON" do
    for json <- ["[]", "null", "broken"] do
      Application.put_env(:mirror_neuron, :native_sdk_grpc_sync_client, fn _, _, _ ->
        {:ok, %{resource_json: json}}
      end)

      assert {:error, reason} = ModelServices.sync_litellm_gateway(%{})
      assert reason =~ "native SDK LiteLLM gateway sync returned"
    end
  end

  test "invalid timeout overrides preserve the caller budget" do
    parent = self()

    Application.put_env(:mirror_neuron, :native_sdk_grpc_sync_client, fn _, _, timeout ->
      send(parent, {:timeout, timeout})
      {:ok, %{resource_json: "{}"}}
    end)

    for invalid <- ["0", "-1", "12junk"] do
      System.put_env("MN_NATIVE_SDK_GRPC_TIMEOUT_MS", invalid)
      assert {:ok, %{}} = ModelServices.sync_litellm_gateway(%{}, 4321)
      assert_receive {:timeout, 4321}
    end
  end
end
