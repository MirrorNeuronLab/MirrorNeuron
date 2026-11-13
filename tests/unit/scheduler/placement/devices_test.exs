defmodule MirrorNeuron.Scheduler.Placement.DevicesTest do
  use MirrorNeuron.SchedulerCase, async: false

  test "one reserved GPU can serve multiple workers and models within one run" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "shared-run-gpu",
        "entrypoints" => ["a", "b"],
        "nodes" =>
          Enum.map(["a", "b"], fn id ->
            %{
              "node_id" => id,
              "agent_type" => "executor",
              "resources" => %{"cpu_cores" => 1, "memory_mb" => 1024, "gpu_count" => 1}
            }
          end),
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest, nodes: [cuda_node()], jobs: [], exclusive_run: true)

    assert length(plan["placements"]) == 2
    assert Enum.all?(plan["placements"], &(&1["node"] == "cuda@lab"))

    ids =
      Enum.map(plan["placements"], &get_in(&1, ["allocations", "devices", Access.at(0), "id"]))

    assert Enum.uniq(ids) == ["cuda-0"]
  end

  test "device-style GPU resources are counted during placement" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "multi-gpu-device",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "cpu_cores" => 1,
              "memory_mb" => 4096,
              "devices" => [%{"type" => "nvidia/gpu", "count" => 2}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [gpu_node(), multi_gpu_node()],
               jobs: []
             )

    assert [
             %{
               "agent_id" => "worker",
               "node" => "multi-gpu@lab",
               "resources" => %{"cpu_cores" => 1, "memory_mb" => 4096, "gpu_count" => 2}
             }
           ] = plan["placements"]
  end

  test "hardware-derived GPU capabilities are enough for NVIDIA-specific and Metal placement" do
    {:ok, nvidia_manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "hardware-derived-nvidia",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"gpu_count" => 1},
            "constraints" => [
              %{
                "attribute" => "capabilities",
                "operator" => "contains",
                "value" => "nvidia-h100"
              }
            ]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, nvidia_plan} =
             Scheduler.plan(nvidia_manifest,
               nodes: [small_node(), capabilityless_h100_node()],
               jobs: []
             )

    assert [%{"node" => "h100@lab"}] = nvidia_plan["placements"]

    {:ok, metal_manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "hardware-derived-metal",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"gpu_count" => 1},
            "constraints" => [
              %{"attribute" => "capabilities", "operator" => "contains", "value" => "metal"}
            ]
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, metal_plan} =
             Scheduler.plan(metal_manifest,
               nodes: [small_node(), capabilityless_metal_node()],
               jobs: []
             )

    assert [%{"node" => "metal@lab"}] = metal_plan["placements"]
  end

  test "GPU-required placement fails instead of falling back to CPU-only nodes" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "gpu-required-no-cpu-fallback",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [%{"kind" => "gpu", "driver" => "cuda", "count" => 1}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [small_node(), large_node()], jobs: [])

    assert reason =~ "worker"
    assert reason =~ "small@lab: insufficient resources"
    assert reason =~ "large@lab: insufficient resources"
  end

  test "GPU-required placement stays blocked while GPU node is offline" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "gpu-required-node-left",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [%{"kind" => "gpu", "driver" => "cuda", "count" => 1}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    offline_gpu =
      cuda_node("gpu-left@lab")
      |> Map.put("status", "offline")
      |> Map.put("scheduling_eligible", false)

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [small_node(), offline_gpu], jobs: [])

    assert reason =~ "worker"
    assert reason =~ "small@lab: insufficient resources"
    assert reason =~ "gpu-left@lab: status \"offline\""

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [small_node(), cuda_node("gpu-left@lab")],
               jobs: []
             )

    assert [%{"agent_id" => "worker", "node" => "gpu-left@lab"}] = plan["placements"]
  end

  test "GPU device placement follows refreshed node capabilities" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "cuda-capability-refresh",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [%{"kind" => "gpu", "driver" => "cuda"}]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    stale_cuda_host =
      cuda_node()
      |> Map.put("capabilities", ["cpu"])
      |> put_in(["hardware", "gpu"], "Unknown or None")

    assert {:error, "placement_failed: " <> reason} =
             Scheduler.plan(manifest, nodes: [small_node(), stale_cuda_host], jobs: [])

    assert reason =~ "worker"
    assert reason =~ "small@lab: insufficient resources"
    assert reason =~ "cuda@lab: insufficient resources"

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [small_node(), cuda_node()], jobs: [])

    assert [%{"node" => "cuda@lab", "allocations" => %{"devices" => [device]}}] =
             plan["placements"]

    assert device["driver"] == "cuda"
  end

  test "CUDA and Metal device requests only place on matching device drivers" do
    {:ok, cuda_manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "cuda-device",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [
                %{"kind" => "gpu", "driver" => "cuda", "min_memory_mb" => 16_000}
              ]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, cuda_plan} =
             Scheduler.plan(cuda_manifest, nodes: [metal_node(), cuda_node()], jobs: [])

    assert [%{"node" => "cuda@lab", "allocations" => %{"devices" => [cuda_device]}}] =
             cuda_plan["placements"]

    assert cuda_device["id"] == "cuda-0"
    assert cuda_device["driver"] == "cuda"

    {:ok, metal_manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "metal-device",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"devices" => [%{"kind" => "gpu", "driver" => "metal"}]}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, metal_plan} =
             Scheduler.plan(metal_manifest, nodes: [cuda_node(), metal_node()], jobs: [])

    assert [%{"node" => "metal@lab", "allocations" => %{"devices" => [metal_device]}}] =
             metal_plan["placements"]

    assert metal_device["driver"] == "metal"
  end

  test "vendor-qualified GPU device type avoids mismatched advertised vendors" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "vendor-device-type",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"devices" => [%{"type" => "nvidia/gpu"}]}
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:ok, plan} = Scheduler.plan(manifest, nodes: [metal_node(), cuda_node()], jobs: [])
    assert [%{"node" => "cuda@lab"}] = plan["placements"]
  end

  test "device memory rejection reports measured admission blockers without lowering requirements" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "memory-admission",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [
                %{
                  "kind" => "gpu",
                  "vendor" => "nvidia",
                  "driver" => "cuda",
                  "min_memory_mb" => 49_152
                }
              ]
            }
          }
        ],
        "edges" => []
      })

    node = h100_node() |> Map.put("display_name", "spark")

    node =
      update_in(node, ["hardware", "gpu"], fn devices ->
        Enum.map(devices, &Map.put(&1, "memory_free_mb", 8192))
      end)

    assert {:error, reason} = Scheduler.plan(manifest, nodes: [node], jobs: [])
    assert reason =~ "placement_failed:"
    [_, payload] = String.split(reason, "\nmn_admission_v1:")

    assert %{
             "blockers" => [
               %{
                 "code" => "MN_GPU_MEMORY_UNAVAILABLE",
                 "node_label" => "spark",
                 "required" => 48.0,
                 "available" => 8.0,
                 "unit" => "GiB",
                 "resource" => "gpu_memory_free_mb",
                 "operator" => ">="
               }
             ]
           } = Jason.decode!(payload)

    refute payload =~ "h100@lab"
    assert {:ok, _} = Scheduler.plan(manifest, nodes: [h100_node()], jobs: [])
  end

  test "strict CUDA API and GPU memory device requirements filter placement" do
    {:ok, manifest} =
      load_manifest(%{
        "manifest_version" => "1.0",
        "graph_id" => "strict-gpu-device",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "devices" => [
                %{
                  "kind" => "gpu",
                  "vendor" => "nvidia",
                  "driver" => "cuda",
                  "min_api_version" => "12.0",
                  "api_version_operator" => ">",
                  "min_memory_mb" => 49_152,
                  "memory_operator" => ">"
                }
              ]
            }
          }
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "local_restart"}
      })

    assert {:error, exact_cuda_reason} =
             Scheduler.plan(manifest,
               nodes: [h100_node() |> put_gpu_api_version("12.0")],
               jobs: []
             )

    assert exact_cuda_reason =~ "devices, ports, volumes, or runtime driver not available"
    refute exact_cuda_reason =~ "MN_GPU_MEMORY_UNAVAILABLE"

    assert {:error, exact_memory_reason} =
             Scheduler.plan(
               manifest,
               nodes: [h100_node() |> put_gpu_api_version("12.1") |> put_gpu_memory(49_152)],
               jobs: []
             )

    assert exact_memory_reason =~ "devices, ports, volumes, or runtime driver not available"
    assert exact_memory_reason =~ "MN_GPU_MEMORY_UNAVAILABLE"
    assert exact_memory_reason =~ ~s("operator":">")

    assert {:error, split_memory_reason} =
             Scheduler.plan(manifest,
               nodes: [cuda_node() |> put_gpu_api_version("12.1")],
               jobs: []
             )

    assert split_memory_reason =~ "devices, ports, volumes, or runtime driver not available"

    assert {:ok, plan} =
             Scheduler.plan(manifest,
               nodes: [h100_node() |> put_gpu_api_version("12.1")],
               jobs: []
             )

    assert [%{"node" => "h100@lab", "allocations" => %{"devices" => [device]}}] =
             plan["placements"]

    assert device["id"] == "h100-0"
  end
end
