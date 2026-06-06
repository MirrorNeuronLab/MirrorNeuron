defmodule MirrorNeuron.Cluster.HardwareTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.Hardware

  setup do
    saved_env =
      Map.new(
        [
          "MN_NODE_GPU",
          "MN_NODE_GPU_COUNT",
          "MN_NODE_DISPLAY_NAME",
          "MN_NODE_CAPABILITIES",
          "MN_NODE_GPU_VENDOR",
          "MN_NODE_GPU_DRIVER",
          "MN_NODE_GPU_TYPE",
          "MN_NODE_GPU_NAME"
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

  test "derives high-end NVIDIA capability tags from GPU names" do
    [gpu] =
      Hardware.parse_nvidia_gpu("""
      0, GPU-H100, NVIDIA H100 80GB HBM3, 2, 1024, 80896, 81920
      """)

    assert "nvidia-h100" in gpu.capabilities
  end

  test "treats NVIDIA GB10 shared memory as CUDA GPU memory" do
    [gpu] =
      Hardware.parse_nvidia_gpu(
        """
        0, GPU-GB10, NVIDIA GB10, [N/A], [N/A], [N/A], [N/A]
        """,
        %{"total_mb" => 131_072, "available_mb" => 120_000}
      )

    assert gpu.name == "NVIDIA GB10"
    assert gpu.memory_total_mb == 131_072
    assert gpu.memory_free_mb == 120_000
    assert "nvidia-gb10" in gpu.capabilities
  end

  test "treats NVIDIA DGX Spark shared memory as CUDA GPU memory" do
    [gpu] =
      Hardware.parse_nvidia_gpu(
        """
        0, GPU-SPARK, NVIDIA DGX Spark, [N/A], [N/A], [N/A], [N/A]
        """,
        %{"total_mb" => 165_000, "available_mb" => 128_000}
      )

    assert gpu.name == "NVIDIA DGX Spark"
    assert gpu.memory_total_mb == 165_000
    assert gpu.memory_free_mb == 128_000
    assert "nvidia-dgx-spark" in gpu.capabilities
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

  test "derives Apple GPU capability tags from GPU names" do
    [gpu] =
      Hardware.parse_darwin_gpu(
        """
        Graphics/Displays:
            Chipset Model: Apple M4 Max
        """,
        %{"total_mb" => 65_536, "available_mb" => 40_000}
      )

    assert "apple-m4" in gpu.capabilities
    assert "apple-max" in gpu.capabilities
  end

  test "uses runtime-provided GPU count when host detection happened outside the container" do
    System.put_env("MN_NODE_GPU_COUNT", "2")
    hardware = Hardware.info()

    assert length(hardware.gpu) == 2
    assert Enum.all?(hardware.gpu, &(&1.kind == "gpu"))
    assert Enum.all?(hardware.gpu, &("gpu" in &1.capabilities))
  end

  test "annotates runtime-provided Spark GPU count with NVIDIA identity" do
    System.put_env("MN_NODE_GPU_COUNT", "1")
    System.put_env("MN_NODE_DISPLAY_NAME", "spark")

    hardware = Hardware.info()
    [gpu] = hardware.gpu

    assert gpu.name == "NVIDIA DGX Spark"
    assert gpu.vendor == "nvidia"
    assert gpu.driver == "cuda"
    assert gpu.type == "nvidia/gpu"
    assert "nvidia-dgx-spark" in gpu.capabilities
    assert "nvidia" in hardware.capabilities
  end

  test "annotates runtime-provided Apple GPU count with Metal identity" do
    System.put_env("MN_NODE_GPU_COUNT", "1")
    System.put_env("MN_NODE_DISPLAY_NAME", "Homers-MacBook-Air")

    hardware = Hardware.info()
    [gpu] = hardware.gpu

    assert gpu.name == "Apple Metal GPU"
    assert gpu.vendor == "apple"
    assert gpu.driver == "metal"
    assert gpu.type == "apple/gpu"
    assert "unified-memory" in hardware.capabilities
  end

  test "adds operator-provided node capabilities to hardware info" do
    System.put_env("MN_NODE_GPU_COUNT", "0")
    System.put_env("MN_NODE_CAPABILITIES", "nvidia-b200, lab-llm")

    hardware = Hardware.info()

    assert "nvidia-b200" in hardware.capabilities
    assert "lab-llm" in hardware.capabilities
  end

  test "adds host identity to platform info" do
    System.put_env("MN_NODE_DISPLAY_NAME", "lab-box")
    hardware = Hardware.info()

    assert hardware.platform.display_name == "lab-box"
    assert is_binary(hardware.platform.hostname)
  end
end
