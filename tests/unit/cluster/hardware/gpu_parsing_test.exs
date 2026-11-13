defmodule MirrorNeuron.Cluster.HardwareTest.GpuParsingTest do
  use MirrorNeuron.HardwareCase, async: false

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
    assert gpu.model == "NVIDIA RTX 4090"
    assert gpu.memory_total_mb == 24_576.0
    assert gpu.memory_free_mb == 22_528.0
    assert "cuda" in gpu.capabilities
  end

  test "adds NVIDIA CUDA version to GPU type" do
    [gpu] =
      Hardware.parse_nvidia_gpu(
        """
        0, GPU-123, NVIDIA RTX 4090, 550.54, 12, 2048, 22528, 24576
        """,
        %{},
        %{"cuda_version" => "12.4"}
      )

    assert gpu.driver_version == "550.54"
    assert gpu.api == "cuda"
    assert gpu.api_version == "12.4"
    assert gpu.gpu_type == "nvidia-cuda-12.4"
  end

  test "parses AMD and Intel Linux PCI GPU inventory" do
    [amd, intel] =
      Hardware.parse_lspci_gpu(
        ~s(03:00.0 "VGA compatible controller" "Advanced Micro Devices, Inc. [AMD/ATI]" "Navi 31 [Radeon RX 7900 XTX]"\n00:02.0 "VGA compatible controller" "Intel Corporation" "Arc Graphics"),
        "6.1"
      )

    assert amd.vendor == "amd"
    assert amd.driver == "rocm"
    assert amd.api_version == "6.1"
    assert amd.gpu_type == "amd-rocm-6.1"
    assert amd.model == "Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XTX]"

    assert intel.vendor == "intel"
    assert intel.driver == "intel"
    assert intel.gpu_type == "intel"
    assert intel.model == "Intel Corporation Arc Graphics"
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
    assert gpu.model == "Apple M2 Max"
    assert gpu.api == "metal"
    assert gpu.gpu_type == "mac-metal"
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
end
