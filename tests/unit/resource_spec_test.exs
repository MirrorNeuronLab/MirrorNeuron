defmodule MirrorNeuron.ResourceSpecTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ResourceSpec

  test "normalizes rich resource requests while preserving legacy scalar fields" do
    spec =
      ResourceSpec.normalize_request(%{
        "cpu" => 1500,
        "memory_gb" => 8,
        "disk_gb" => 20,
        "devices" => [
          %{
            "kind" => "gpu",
            "count" => 2,
            "driver" => "cuda",
            "min_memory_mb" => 16_000,
            "capabilities" => ["tensor-cores"]
          }
        ],
        "ports" => [%{"label" => "api", "port" => 8080}],
        "volumes" => [
          %{"name" => "models", "source" => "/srv/models", "target" => "/models", "mode" => "ro"}
        ],
        "runtime_driver" => "openshell"
      })

    assert spec["resources"] == %{
             "cpu_cores" => 1.5,
             "memory_mb" => 8192,
             "disk_mb" => 20_480,
             "gpu_count" => 2
           }

    assert [%{"count" => 2, "driver" => "cuda", "min_memory_mb" => 16_000}] =
             spec["devices"]

    assert [%{"label" => "api", "port" => 8080, "protocol" => "tcp"}] = spec["ports"]
    assert [%{"name" => "models", "source" => "/srv/models"}] = spec["volumes"]
    assert spec["runtime_driver"] == "openshell"
  end

  test "normalizes node devices from CUDA and Metal inventories" do
    devices =
      ResourceSpec.normalize_node_devices(%{
        "hardware" => %{
          "gpu" => [
            %{
              "id" => "GPU-abc",
              "name" => "NVIDIA RTX",
              "vendor" => "nvidia",
              "driver" => "cuda",
              "memory_total_mb" => 24_576,
              "memory_free_mb" => 20_000
            },
            %{
              "id" => "metal-0",
              "name" => "Apple M",
              "vendor" => "apple",
              "driver" => "metal"
            }
          ]
        }
      })

    assert Enum.any?(devices, &(&1["id"] == "GPU-abc" and &1["driver"] == "cuda"))
    assert Enum.any?(devices, &("metal" in &1["capabilities"]))
  end

  test "builds allocation environment hints" do
    env =
      ResourceSpec.allocation_env(%{
        "devices" => [
          %{"id" => "GPU-abc", "index" => 1, "driver" => "cuda"},
          %{"id" => "metal-0", "driver" => "metal"}
        ],
        "ports" => [%{"label" => "agent-api", "port" => 8080}],
        "volumes" => [%{"name" => "models", "source" => "/srv/models", "target" => "/models"}]
      })

    assert env["MN_ALLOCATED_DEVICE_IDS"] == "GPU-abc,metal-0"
    assert env["CUDA_VISIBLE_DEVICES"] == "1"
    assert env["MN_GPU_DRIVER"] == "cuda,metal"
    assert env["MN_PORT_AGENT_API"] == "8080"
    assert env["MN_VOLUME_MODELS"] == "/srv/models"
    assert env["MN_VOLUME_MODELS_TARGET"] == "/models"
    assert {:ok, _decoded} = Jason.decode(env["MN_ALLOCATION_JSON"])
  end

  test "validates malformed rich resource specs" do
    errors =
      ResourceSpec.validate_node(%{
        node_id: "worker",
        resources: %{
          "devices" => [%{"count" => 0, "min_memory_mb" => -1}],
          "ports" => [
            %{"label" => "api", "port" => 8080},
            %{"label" => "api", "port" => 70_000}
          ],
          "volumes" => [
            %{"name" => "cache", "source" => "relative", "target" => "cache", "mode" => "bad"}
          ],
          "runtime_driver" => ""
        }
      })

    assert Enum.any?(errors, &String.contains?(&1, "count must be greater than zero"))
    assert Enum.any?(errors, &String.contains?(&1, "duplicate port label"))
    assert Enum.any?(errors, &String.contains?(&1, "port must be between"))
    assert Enum.any?(errors, &String.contains?(&1, "absolute host path"))
    assert Enum.any?(errors, &String.contains?(&1, "runtime_driver"))
  end
end
