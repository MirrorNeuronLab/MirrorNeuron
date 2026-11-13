defmodule MirrorNeuron.SchedulerCase do
  use ExUnit.CaseTemplate
  alias MirrorNeuron.Manifest

  using do
    quote do
      alias MirrorNeuron.Scheduler
      import MirrorNeuron.SchedulerCase
    end
  end

  defmodule ResourceStore do
    def fetch_resource_limits, do: {:error, "not configured"}
  end

  setup do
    keys = [:execution_profiles, :resource_limits_store]
    previous = Map.new(keys, &{&1, Application.fetch_env(:mirror_neuron, &1)})
    Application.put_env(:mirror_neuron, :resource_limits_store, ResourceStore)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:mirror_neuron, key, value)
        {key, :error} -> Application.delete_env(:mirror_neuron, key)
      end)
    end)
  end

  def load_manifest(raw) when is_map(raw) do
    raw = Map.put_new(raw, "apiVersion", "mn.workflow/v1")
    raw = Map.put_new(raw, "kind", "Workflow")

    raw =
      if Map.has_key?(raw, "flow") do
        raw
      else
        raw
        |> Map.put("flow", %{
          "nodes" => Map.get(raw, "nodes", []),
          "edges" => Map.get(raw, "edges", [])
        })
        |> Map.delete("nodes")
        |> Map.delete("edges")
      end

    Manifest.load(raw)
  end

  def small_node do
    %{
      "name" => "small@lab",
      "status" => "healthy",
      "capabilities" => ["cpu"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 4},
        "memory" => %{"available_mb" => 4096},
        "disk" => %{"available_mb" => 100_000},
        "gpu" => "Unknown or None"
      }
    }
  end

  def large_node do
    %{
      "name" => "large@lab",
      "status" => "healthy",
      "capabilities" => ["cpu"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 8},
        "memory" => %{"available_mb" => 16_384},
        "disk" => %{"available_mb" => 200_000},
        "gpu" => "Unknown or None"
      }
    }
  end

  def gpu_node do
    %{
      "name" => "gpu@lab",
      "status" => "healthy",
      "capabilities" => ["cuda", "llm"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 16},
        "memory" => %{"available_mb" => 65_536},
        "disk" => %{"available_mb" => 500_000},
        "gpu" => [%{"name" => "NVIDIA RTX"}]
      }
    }
  end

  def multi_gpu_node do
    %{
      "name" => "multi-gpu@lab",
      "status" => "healthy",
      "capabilities" => ["cuda", "llm"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 16},
        "memory" => %{"available_mb" => 65_536},
        "disk" => %{"available_mb" => 500_000},
        "gpu" => [%{"name" => "GPU 1"}, %{"name" => "GPU 2"}]
      }
    }
  end

  def cuda_node(name \\ "cuda@lab") do
    %{
      "name" => name,
      "status" => "healthy",
      "capabilities" => ["cuda", "llm"],
      "runtime_drivers" => ["host_local"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 16},
        "memory" => %{"available_mb" => 65_536},
        "disk" => %{"available_mb" => 500_000},
        "gpu" => [
          %{
            "id" => "cuda-0",
            "index" => 0,
            "name" => "NVIDIA RTX 4090",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 24_576,
            "memory_free_mb" => 20_000,
            "capabilities" => ["gpu", "cuda", "nvidia"]
          },
          %{
            "id" => "cuda-1",
            "index" => 1,
            "name" => "NVIDIA RTX 3090",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 24_576,
            "memory_free_mb" => 12_000,
            "capabilities" => ["gpu", "cuda", "nvidia"]
          }
        ]
      }
    }
  end

  def h100_node do
    %{
      "name" => "h100@lab",
      "status" => "healthy",
      "capabilities" => ["cuda", "nvidia", "nvidia-h100", "llm"],
      "runtime_drivers" => ["host_local"],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 32},
        "memory" => %{"available_mb" => 131_072},
        "disk" => %{"available_mb" => 1_000_000},
        "gpu" => [
          %{
            "id" => "h100-0",
            "index" => 0,
            "name" => "NVIDIA H100 80GB HBM3",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 81_920,
            "memory_free_mb" => 80_000,
            "capabilities" => ["gpu", "cuda", "nvidia", "nvidia-h100"]
          }
        ]
      }
    }
  end

  def put_gpu_api_version(node, version) do
    update_in(node, ["hardware", "gpu"], fn gpus ->
      Enum.map(gpus, &Map.put(&1, "api_version", version))
    end)
  end

  def put_gpu_memory(node, memory_mb) do
    update_in(node, ["hardware", "gpu"], fn gpus ->
      Enum.map(gpus, fn gpu ->
        gpu
        |> Map.put("memory_total_mb", memory_mb)
        |> Map.put("memory_free_mb", memory_mb)
      end)
    end)
  end

  def capabilityless_h100_node do
    h100_node()
    |> Map.delete("capabilities")
  end

  def model_service(model, node) do
    %{
      "id" => "#{node}:docker-model-runner:#{model}",
      "name" => "docker-model-runner",
      "node" => node,
      "provider" => "mirror_neuron",
      "origin" => "external",
      "status" => "passing",
      "tags" => ["docker-model-runner", "model:#{model}", "model-id:#{model}"],
      "meta" => %{
        "model_id" => model,
        "model" => model,
        "model_provider" => "docker_model_runner"
      }
    }
  end

  def model_service_requirement(model) do
    %{
      "name" => "docker-model-runner",
      "tags" => ["model-id:#{model}", "model:#{model}"],
      "required" => true
    }
  end

  def model_placement_requirement(model, required_capabilities \\ []) do
    %{
      "id" => model,
      "model" => model,
      "provider" => "docker_model_runner",
      "service" => model_service_requirement(model),
      "required_capabilities" => required_capabilities
    }
  end

  def metal_node do
    %{
      "name" => "metal@lab",
      "status" => "healthy",
      "capabilities" => ["metal", "llm"],
      "runtime_drivers" => ["host_local"],
      "hardware" => %{
        "platform" => %{"os" => "darwin"},
        "cpu" => %{"logical_processors" => 12},
        "memory" => %{"available_mb" => 32_768},
        "disk" => %{"available_mb" => 300_000},
        "gpu" => [
          %{
            "id" => "metal-0",
            "index" => 0,
            "name" => "Apple M2 Max",
            "kind" => "gpu",
            "type" => "apple/gpu",
            "vendor" => "apple",
            "driver" => "metal",
            "memory_total_mb" => 32_768,
            "memory_free_mb" => 20_000,
            "capabilities" => ["gpu", "apple", "metal"]
          }
        ]
      }
    }
  end

  def capabilityless_metal_node do
    metal_node()
    |> Map.delete("capabilities")
  end

  def restore_env(name, nil), do: System.delete_env(name)
  def restore_env(name, value), do: System.put_env(name, value)
end
