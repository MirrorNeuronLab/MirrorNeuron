defmodule MirrorNeuron.Cluster.Hardware.SnapshotsTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Cluster.Hardware

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
