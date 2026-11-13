defmodule MirrorNeuron.Cluster.HardwareTest.AdvertisementTest do
  use MirrorNeuron.HardwareCase, async: false

  alias MirrorNeuron.Cluster.Hardware

  test "uses runtime-provided GPU count when host detection happened outside the container" do
    System.put_env("MN_NODE_GPU_COUNT", "2")
    hardware = Hardware.info()

    assert length(hardware.gpu) == 2
    assert Enum.all?(hardware.gpu, &(&1.kind == "gpu"))
    assert Enum.all?(hardware.gpu, &is_binary(&1.model))
    assert Enum.all?(hardware.gpu, &("gpu" in &1.capabilities))
  end

  test "adds CPU model to hardware info" do
    System.put_env("MN_NODE_GPU_COUNT", "0")
    System.put_env("MN_NODE_CPU_MODEL", "AMD Ryzen AI Max+ 395")

    hardware = Hardware.info()

    assert hardware.cpu.model == "AMD Ryzen AI Max+ 395"
  end

  test "annotates runtime-provided Spark GPU count with NVIDIA identity" do
    System.put_env("MN_NODE_GPU_COUNT", "1")
    System.put_env("MN_NODE_DISPLAY_NAME", "spark")
    System.put_env("MN_NODE_GPU_API_VERSION", "12.6")

    hardware = Hardware.info()
    [gpu] = hardware.gpu

    assert gpu.name == "NVIDIA DGX Spark"
    assert gpu.vendor == "nvidia"
    assert gpu.driver == "cuda"
    assert gpu.type == "nvidia/gpu"
    assert gpu.api_version == "12.6"
    assert gpu.gpu_type == "nvidia-cuda-12.6"
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
    assert gpu.gpu_type == "mac-metal"
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

  test "uses SDK-advertised hardware JSON as the source of truth" do
    System.put_env(
      "MN_NODE_HARDWARE_JSON",
      Jason.encode!(%{
        "platform" => %{"display_name" => "sdk-node", "hostname" => "sdk-host"},
        "cpu" => %{"logical_processors" => 16, "model" => "SDK CPU"},
        "memory" => %{"total_mb" => 65_536, "available_mb" => 60_000},
        "disk" => %{"total_mb" => 1_000_000, "available_mb" => 900_000},
        "gpu" => [],
        "devices" => [],
        "capabilities" => ["sdk-advertised"],
        "host_paths" => ["/srv/mn"],
        "runtime_drivers" => ["host_local", "docker_worker"]
      })
    )

    hardware = Hardware.info()

    assert hardware.platform.display_name == "sdk-node"
    assert hardware.cpu.logical_processors == 16
    assert hardware.memory.total_mb == 65_536
    assert hardware.host_paths == ["/srv/mn"]
    assert hardware.runtime_drivers == ["host_local", "docker_worker"]
    assert "sdk-advertised" in hardware.capabilities
  end

  test "does not probe docker daemon to advertise docker_worker" do
    System.put_env("MN_DOCKER_WORKER_ENABLED", "1")
    System.put_env("MN_DOCKER_BIN", "false")

    assert "docker_worker" in Hardware.info().runtime_drivers

    System.put_env("MN_DOCKER_WORKER_ENABLED", "0")
    refute "docker_worker" in Hardware.info().runtime_drivers
  end
end
