defmodule MirrorNeuron.Cluster.Hardware.SnapshotsTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Cluster.Hardware
  alias MirrorNeuron.Cluster.Manager
  alias MirrorNeuron.Execution.LeaseManager

  setup do
    previous = :persistent_term.get({Hardware, :snapshot}, :missing)

    on_exit(fn ->
      if previous == :missing,
        do: Hardware.clear_snapshot(),
        else: :persistent_term.put({Hardware, :snapshot}, previous)
    end)

    :ok
  end

  test "fresh telemetry keeps its identity and available capacity" do
    assert :ok =
             Hardware.update_snapshot(%{
               "memory" => %{"available_mb" => 42},
               "gpu" => [],
               "capabilities" => ["cuda"]
             })

    assert %{admission_telemetry_current: true, memory: %{available_mb: 42}} = Hardware.info()
    assert "cuda" in Hardware.info().capabilities
  end

  test "cluster hardware encodes one native SDK route with the advertised capabilities" do
    unless Process.whereis(LeaseManager), do: start_supervised!(LeaseManager)

    assert :ok =
             Hardware.update_snapshot(%{
               "native_sdk_grpc" => %{"capabilities" => ["custom_hf_model_v1"]},
               "cpu" => %{"logical_processors" => 4}
             })

    {_lease_stats, hardware} = Manager.local_info()
    assert {:ok, encoded} = Jason.encode(hardware, maps: :strict)

    assert %{
             "native_sdk_grpc" => %{"capabilities" => ["custom_hf_model_v1"]},
             "cpu" => %{"logical_processors" => 4}
           } = Jason.decode!(encoded)
  end

  test "only Core attests Wasmtime across initial and refreshed native reports" do
    keys = ~w(MN_WASMTIME_BIN MN_WASMTIME_HOST_BIN MN_NODE_HARDWARE_JSON)
    old = Map.take(System.get_env(), keys)

    on_exit(fn ->
      Enum.each(keys, &System.delete_env/1)
      System.put_env(old)
    end)

    executable = System.find_executable("sh")
    assert is_binary(executable)
    System.put_env("MN_WASMTIME_BIN", executable)
    System.put_env("MN_WASMTIME_HOST_BIN", executable)
    System.put_env("MN_NODE_HARDWARE_JSON", ~s({"runtime_drivers":["host_local"]}))
    Hardware.clear_snapshot()
    assert Hardware.info().runtime_drivers == ["host_local", "wasmtime"]

    Hardware.update_snapshot(%{"runtime_drivers" => ["docker_worker"]})
    assert Hardware.info().runtime_drivers == ["docker_worker", "wasmtime"]

    Hardware.update_snapshot(%{"runtime_drivers" => ["docker_worker", "wasmtime"]})
    assert Hardware.info().runtime_drivers == ["docker_worker", "wasmtime"]

    for key <- ~w(MN_WASMTIME_BIN MN_WASMTIME_HOST_BIN) do
      System.put_env(key, "/missing-mn-test/wasmtime")
      assert Hardware.info().runtime_drivers == ["docker_worker"]
      System.put_env(key, executable)
    end
  end

  test "stale telemetry withdraws free CPU memory and device memory" do
    snapshot = %{
      memory: %{total_mb: 64, available_mb: 42},
      gpu: [%{memory_free_mb: 32}],
      devices: [%{memory_free_mb: 32}],
      capabilities: []
    }

    :persistent_term.put({Hardware, :snapshot}, {System.monotonic_time(:second) - 91, snapshot})
    hardware = Hardware.info()
    refute hardware.admission_telemetry_current
    assert hardware.memory.available_mb == 0
    assert hardware.memory.total_mb == 64
    assert [%{memory_free_mb: 0}] = hardware.gpu
    assert [%{memory_free_mb: 0}] = hardware.devices
  end

  test "malformed optional telemetry cannot crash stale capacity withdrawal" do
    :persistent_term.put(
      {Hardware, :snapshot},
      {System.monotonic_time(:second) - 91,
       %{memory: nil, gpu: "unavailable", devices: [nil], capabilities: nil}}
    )

    hardware = Hardware.info()
    refute hardware.admission_telemetry_current
    assert hardware.memory.available_mb == 0
    assert hardware.gpu == []
    assert hardware.devices == []
    assert hardware.capabilities == ["resource_admission_v2"]
  end

  test "novel telemetry keys never allocate atoms" do
    key = "telemetry_unknown_#{System.unique_integer([:positive])}"
    assert :ok = Hardware.update_snapshot(%{key => "retained"})
    assert Hardware.info()[key] == "retained"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end
end
