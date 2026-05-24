defmodule MirrorNeuron.Cluster.HardwareTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Cluster.Hardware

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
end
