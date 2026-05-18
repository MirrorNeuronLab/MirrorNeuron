defmodule MirrorNeuron.ResourceAdmissionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MirrorNeuron.ResourceAdmission

  defmodule OverloadedHardware do
    def info do
      %{
        cpu: %{load_ratio: 0.2},
        memory: %{used_ratio: 0.99},
        gpu: []
      }
    end
  end

  setup do
    keys = [
      "MN_RESOURCE_ADMISSION_ENABLED",
      "MN_MAX_CPU_LOAD_RATIO",
      "MN_MAX_MEMORY_USED_RATIO",
      "MN_MAX_GPU_UTILIZATION_RATIO",
      "MN_MAX_GPU_MEMORY_USED_RATIO"
    ]

    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Application.delete_env(:mirror_neuron, :hardware_module)
    end)

    :ok
  end

  test "accepts jobs when resource pressure is below thresholds" do
    snapshot = %{
      cpu: %{load_ratio: 0.2},
      memory: %{used_ratio: 0.4},
      gpu: [%{utilization_ratio: 0.5, memory_used_ratio: 0.6}]
    }

    assert :ok = ResourceAdmission.check(snapshot)
  end

  test "rejects jobs and logs a warning when resources are overloaded" do
    System.put_env("MN_MAX_CPU_LOAD_RATIO", "1.5")
    System.put_env("MN_MAX_MEMORY_USED_RATIO", "0.95")
    System.put_env("MN_MAX_GPU_UTILIZATION_RATIO", "0.98")
    System.put_env("MN_MAX_GPU_MEMORY_USED_RATIO", "0.98")

    snapshot = %{
      cpu: %{load_ratio: 2.0},
      memory: %{used_ratio: 0.99},
      gpu: [%{utilization_ratio: 0.99, memory_used_ratio: 0.99}]
    }

    log =
      capture_log(fn ->
        assert {:error, "resource_overloaded:" <> reason} = ResourceAdmission.check(snapshot)
        assert reason =~ "cpu"
        assert reason =~ "memory"
        assert reason =~ "gpu_0"
      end)

    assert log =~ "not accepting a new job"
    assert log =~ "resources are overloaded"
  end

  test "can disable resource admission with MN_RESOURCE_ADMISSION_ENABLED" do
    System.put_env("MN_RESOURCE_ADMISSION_ENABLED", "false")

    snapshot = %{cpu: %{load_ratio: 99.0}, memory: %{used_ratio: 0.99}}

    assert :ok = ResourceAdmission.check(snapshot)
  end

  test "run_manifest rejects before loading work when local resource pressure is high" do
    Application.put_env(:mirror_neuron, :hardware_module, OverloadedHardware)
    System.put_env("MN_MAX_MEMORY_USED_RATIO", "0.000001")

    log =
      capture_log(fn ->
        assert {:error, "resource_overloaded:" <> _reason} =
                 MirrorNeuron.run_manifest("not a manifest")
      end)

    assert log =~ "not accepting a new job"
  end
end
