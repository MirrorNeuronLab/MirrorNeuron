defmodule MirrorNeuron.Cluster.HardwareTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.Hardware

  setup do
    saved_env =
      Map.new(["MN_NODE_GPU", "MN_NODE_GPU_COUNT", "MN_NODE_DISPLAY_NAME"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "parses rich NVIDIA GPU inventory" do
    [gpu] =
      Hardware.parse_nvidia_gpu("""
      0, GPU-123, NVIDIA RTX 4090, 12, 2048, 22528, 24576
      """)

    assert gpu.id == "GPU-123"
    assert gpu.index == 0
    assert gpu.vendor == "nvidia"
    assert gpu.driver == "cuda"
    assert gpu.memory_total_mb == 24_576.0
    assert gpu.memory_free_mb == 22_528.0
    assert "cuda" in gpu.capabilities
  end

  test "parses legacy NVIDIA GPU inventory" do
    [gpu] =
      Hardware.parse_nvidia_gpu("""
      NVIDIA RTX 3090, 50, 1024, 24576
      """)

    assert gpu.id == "nvidia-0"
    assert gpu.memory_free_mb == 23_552.0
  end

  test "parses macOS Metal GPU inventory with unified memory hint" do
    [gpu] =
      Hardware.parse_darwin_gpu(
        """
        Graphics/Displays:
            Chipset Model: Apple M2 Max
        """,
        %{"total_mb" => 32_768, "available_mb" => 20_000}
      )

    assert gpu.id == "metal-0"
    assert gpu.vendor == "apple"
    assert gpu.driver == "metal"
    assert gpu.memory_total_mb == 32_768
    assert "unified_memory" in gpu.capabilities
  end

  test "uses runtime-provided GPU count when host detection happened outside the container" do
    System.put_env("MN_NODE_GPU_COUNT", "2")
    hardware = Hardware.info()

    assert length(hardware.gpu) == 2
    assert Enum.all?(hardware.gpu, &(&1.kind == "gpu"))
    assert Enum.all?(hardware.gpu, &("gpu" in &1.capabilities))
  end

  test "adds host identity to platform info" do
    System.put_env("MN_NODE_DISPLAY_NAME", "lab-box")
    hardware = Hardware.info()

    assert hardware.platform.display_name == "lab-box"
    assert is_binary(hardware.platform.hostname)
  end
end
