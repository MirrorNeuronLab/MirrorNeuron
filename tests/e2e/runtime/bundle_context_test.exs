defmodule MirrorNeuron.Runtime.BundleContextTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.AgentWorker
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.RuntimeTest.BundlePathEchoRunner
  alias MirrorNeuron.RuntimeTest.DelayedCompleteRunner
  alias MirrorNeuron.RuntimeTest.AllocationEchoRunner

  test "passes scheduler allocation metadata into executor runtime environment" do
    node_name = to_string(Node.self())
    volume_root = Path.join(System.tmp_dir!(), "mn-allocation-volume")
    File.mkdir_p!(volume_root)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "allocation_env_runtime_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"start" => true}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => AllocationEchoRunner,
            "output_message_type" => nil
          },
          "resources" => %{
            "devices" => [%{"kind" => "gpu", "driver" => "cuda", "min_memory_mb" => 1024}],
            "ports" => [%{"label" => "api", "port" => 18_080, "protocol" => "tcp"}],
            "volumes" => [
              %{
                "name" => "models",
                "source" => volume_root,
                "target" => "/models",
                "mode" => "ro"
              }
            ]
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    fake_node = %{
      "name" => node_name,
      "status" => "healthy",
      "runtime_drivers" => ["host_local"],
      "host_paths" => [System.tmp_dir!()],
      "hardware" => %{
        "platform" => %{"os" => "linux"},
        "cpu" => %{"logical_processors" => 8},
        "memory" => %{"available_mb" => 16_384},
        "disk" => %{"available_mb" => 100_000},
        "gpu" => [
          %{
            "id" => "GPU-runtime",
            "index" => 0,
            "name" => "NVIDIA Runtime GPU",
            "kind" => "gpu",
            "type" => "nvidia/gpu",
            "vendor" => "nvidia",
            "driver" => "cuda",
            "memory_total_mb" => 8192,
            "memory_free_mb" => 4096,
            "capabilities" => ["gpu", "cuda", "nvidia"]
          }
        ]
      }
    }

    # Admission replans against the owner's current hardware before dispatch.
    # Advertise the device there too, rather than supplying only an initial plan.
    hardware =
      fake_node["hardware"]
      |> Map.put("runtime_drivers", fake_node["runtime_drivers"])
      |> Map.put("host_paths", fake_node["host_paths"])
      |> Map.put("native_sdk_grpc", %{"capabilities" => ["resource_admission_v2"]})

    System.put_env("MN_NODE_HARDWARE_JSON", Jason.encode!(hardware))
    MirrorNeuron.Cluster.Hardware.update_snapshot(hardware)

    assert {:ok, job_id, job} = run_manifest(manifest, await: true, timeout: 2_000)

    assert job["status"] == "completed"

    assert get_in(job, ["result", "output", "allocation", "devices", Access.at(0), "id"]) ==
             "GPU-runtime"

    assert get_in(job, ["result", "output", "env", "MN_ALLOCATED_DEVICE_IDS"]) == "GPU-runtime"
    assert get_in(job, ["result", "output", "env", "CUDA_VISIBLE_DEVICES"]) == "0"
    assert get_in(job, ["result", "output", "env", "MN_PORT_API"]) == "18080"
    assert get_in(job, ["result", "output", "env", "MN_VOLUME_MODELS"]) == volume_root

    RedisStore.delete_job(job_id)
    File.rm_rf(volume_root)
  end

  test "agent workers materialize archived bundles when original bundle path is unavailable" do
    job_id = "remote-bundle-agent-#{System.unique_integer([:positive])}"
    persist_delivery_job(job_id)
    bundle_root = Path.join(System.tmp_dir!(), "#{job_id}-bundle")
    File.mkdir_p!(Path.join(bundle_root, "payloads"))

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => job_id,
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => BundlePathEchoRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => []
    }

    File.write!(Path.join(bundle_root, "manifest.json"), Jason.encode!(flow_manifest(manifest)))

    {:ok, bundle} = MirrorNeuron.JobBundle.load(bundle_root)
    manifest_ref = Runtime.bundle_ref(bundle.manifest, bundle)
    missing_root = Path.join(System.tmp_dir!(), "#{job_id}-missing")
    File.rm_rf!(missing_root)

    node = %{
      node_id: "worker",
      agent_type: "executor",
      role: nil,
      type: "generic",
      config: %{
        "runner_module" => BundlePathEchoRunner,
        "output_message_type" => nil
      }
    }

    runtime_context = %{
      delivery_version: 2,
      lease_epoch: 1,
      bundle_root: missing_root,
      manifest_path: Path.join(missing_root, "manifest.json"),
      payloads_path: Path.join(missing_root, "payloads"),
      manifest_ref: manifest_ref,
      scheduler: %{"placements" => []},
      artifact_refs: []
    }

    {:ok, pid} =
      AgentWorker.start_link({job_id, node, [], [], self(), runtime_context, nil})

    message =
      Message.new(job_id, "runtime", "worker", "init", %{"start" => true}, class: "command")

    GenServer.cast(pid, {:deliver, message})

    consumer = Delivery.consumer_id(job_id, Delivery.coordinator_agent_id())

    delivery =
      Enum.reduce_while(1..100, nil, fn _, _acc ->
        case Delivery.read(job_id, Delivery.coordinator_agent_id(), consumer) do
          {:ok, [delivery]} ->
            if get_in(delivery.message, ["body", "kind"]) == "agent_completed_run" do
              {:halt, delivery}
            else
              assert :ok =
                       Delivery.ack(
                         job_id,
                         Delivery.coordinator_agent_id(),
                         consumer,
                         delivery
                       )

              {:cont, nil}
            end

          {:ok, []} ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

    assert delivery
    result = get_in(delivery.message, ["body", "result"])
    assert result["bundle_root"] == manifest_ref["cache_path"]
    assert result["manifest_path"] == Path.join(manifest_ref["cache_path"], "manifest.json")
    assert result["payloads_path"] == Path.join(manifest_ref["cache_path"], "payloads")
    assert result["bundle_exists"] == true
    assert result["manifest_exists"] == true
    assert result["payloads_exists"] == true

    assert :ok =
             Delivery.ack(
               job_id,
               Delivery.coordinator_agent_id(),
               consumer,
               delivery
             )

    GenServer.stop(pid)
    RedisStore.delete_job(job_id)
    File.rm_rf!(bundle_root)
  end

  test "single node jobs use shared bundle cache as runtime context" do
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    old_shared_root = System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT")

    shared_root =
      Path.join(System.tmp_dir!(), "mn-shared-runtime-#{System.unique_integer([:positive])}")

    System.delete_env("MN_BUNDLE_CACHE_DIR")
    System.put_env("MN_RUNTIME_SHARED_STORAGE_ROOT", shared_root)

    bundle_dir =
      Path.join(System.tmp_dir!(), "mn-shared-bundle-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
      restore_system_env("MN_RUNTIME_SHARED_STORAGE_ROOT", old_shared_root)
      File.rm_rf!(shared_root)
      File.rm_rf!(bundle_dir)
    end)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "shared_bundle_context_runtime_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"start" => true}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => BundlePathEchoRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => []
    }

    File.mkdir_p!(Path.join(bundle_dir, "payloads"))
    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(flow_manifest(manifest)))

    assert {:ok, job_id, job} = MirrorNeuron.run_manifest(bundle_dir, await: true, timeout: 2_000)

    output = bundle_echo_output(job)
    bundle_root = output["bundle_root"]
    assert job["status"] == "completed"
    assert String.starts_with?(bundle_root, Path.join(shared_root, "bundle_cache") <> "/")
    assert output["bundle_exists"] == true
    assert output["manifest_exists"] == true
    assert output["payloads_exists"] == true

    RedisStore.delete_job(job_id)
  end

  test "single node jobs use Redis-backed cache after the source bundle is removed" do
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")

    root =
      Path.join(System.tmp_dir!(), "mn-redis-cache-runtime-#{System.unique_integer([:positive])}")

    cache_dir = Path.join(root, "cache")
    bundle_dir = Path.join(root, "request-bundle")
    System.put_env("MN_BUNDLE_CACHE_DIR", cache_dir)

    on_exit(fn ->
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
      File.rm_rf!(root)
    end)

    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "redis_bundle_context_runtime_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"start" => true}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => BundlePathEchoRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => []
    }

    File.mkdir_p!(Path.join(bundle_dir, "payloads"))
    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(flow_manifest(manifest)))

    assert {:ok, job_id} = MirrorNeuron.run_manifest(bundle_dir, await: false)
    File.rm_rf!(bundle_dir)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)

    output = bundle_echo_output(job)
    assert job["status"] == "completed"
    assert get_in(job, ["manifest_ref", "bundle_storage"]) == "redis"
    assert String.starts_with?(output["bundle_root"], cache_dir <> "/")
    assert output["bundle_exists"] == true
    assert output["manifest_exists"] == true
    assert output["payloads_exists"] == true
    refute File.exists?(bundle_dir)

    RedisStore.delete_job(job_id)
  end

  test "agent child specs do not replicate the Job definition on each worker heap" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "bounded_worker_context",
      "metadata" => %{"domain_descriptor" => String.duplicate("x", 512 * 1024)},
      "entrypoints" => ["idle"],
      "nodes" => [
        %{
          "node_id" => "idle",
          "agent_type" => "executor",
          "config" => %{"runner_module" => DelayedCompleteRunner, "output_message_type" => nil}
        }
      ],
      "edges" => [],
      "policies" => %{"job_type" => "service"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)

    on_exit(fn ->
      MirrorNeuron.cancel(job_id)
      RedisStore.delete_job(job_id)
    end)

    wait_until(fn -> running_status?(job_id) end, 2_000)
    worker = MirrorNeuron.Runtime.Naming.via_agent(job_id, "idle")
    context = :sys.get_state(worker).runtime_context
    refute Map.has_key?(context, :manifest)
    assert :erlang.external_size(context) < 32 * 1024
    assert {:ok, job} = RedisStore.fetch_job(job_id)
    assert byte_size(job["manifest"]["metadata"]["domain_descriptor"]) == 512 * 1024
  end
end
