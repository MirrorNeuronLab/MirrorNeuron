defmodule MirrorNeuron.HardwareCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.HardwareCase
    end
  end

  setup do
    saved_env =
      Map.new(
        [
          "MN_NODE_GPU",
          "MN_NODE_GPU_COUNT",
          "MN_NODE_DISPLAY_NAME",
          "MN_NODE_CPU_MODEL",
          "MN_NODE_CAPABILITIES",
          "MN_NODE_GPU_VENDOR",
          "MN_NODE_GPU_DRIVER",
          "MN_NODE_GPU_TYPE",
          "MN_NODE_GPU_NAME",
          "MN_NODE_GPU_API_VERSION",
          "MN_NODE_GPU_DRIVER_VERSION",
          "MN_NODE_HARDWARE_JSON",
          "MN_NODE_CPU_CORES",
          "MN_NODE_MEMORY_TOTAL_MB",
          "MN_NODE_MEMORY_AVAILABLE_MB",
          "MN_NODE_DISK_TOTAL_MB",
          "MN_NODE_DISK_AVAILABLE_MB",
          "MN_NODE_RUNTIME_DRIVERS",
          "MN_NODE_HOST_PATHS",
          "MN_DOCKER_WORKER_ENABLED",
          "MN_DOCKER_BIN"
        ],
        &{&1, System.get_env(&1)}
      )

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end
end
