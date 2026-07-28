defmodule MirrorNeuron.CustomModelCapabilityAdvertisementTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.Handlers.ClusterHandshake

  @env_names [
    "MN_NODE_HARDWARE_JSON",
    "MN_NATIVE_SDK_GRPC_ADVERTISE_HOST",
    "MN_NATIVE_SDK_GRPC_ADVERTISE_PORT",
    "MN_RUNTIME_SHARED_STORAGE_ROOT",
    "MN_SYNCTHING_RESCAN_INTERVAL_SECONDS"
  ]

  setup do
    previous = Map.new(@env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "node advertisement preserves native SDK custom model capabilities" do
    System.put_env("MN_NATIVE_SDK_GRPC_ADVERTISE_HOST", "192.168.4.173")
    System.put_env("MN_NATIVE_SDK_GRPC_ADVERTISE_PORT", "55052")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", "/tmp/mn-shared")
    System.put_env("MN_SYNCTHING_RESCAN_INTERVAL_SECONDS", "7200")

    System.put_env(
      "MN_NODE_HARDWARE_JSON",
      Jason.encode!(%{
        "platform" => %{},
        "cpu" => %{},
        "memory" => %{},
        "gpu" => [],
        "native_sdk_grpc" => %{
          "capabilities" => ["custom_hf_model_v1"]
        }
      })
    )

    info = ClusterHandshake.node_advertisement_info()

    assert info["native_sdk_grpc"]["target"] == "192.168.4.173:55052"
    assert info["native_sdk_grpc"]["capabilities"] == ["custom_hf_model_v1"]
    assert info["syncthing"]["rescan_interval_seconds"] == 7_200
  end
end
