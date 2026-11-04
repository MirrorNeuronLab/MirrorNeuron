defmodule MirrorNeuron.RuntimeCase do
  @moduledoc """
  A single scheduling owner with fresh hardware telemetry, a private Redis namespace
  and private Job/bundle storage per test. Use the `:mock_gpu` tag to advertise a
  10 GiB CUDA device. Cases must run synchronously.
  """
  use ExUnit.CaseTemplate

  alias MirrorNeuron.Cluster.{Hardware, NodeState}
  alias MirrorNeuron.Persistence.RedisStore

  setup_all do
    unless Node.alive?() do
      :ok = Application.stop(:mirror_neuron)
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = String.to_atom("runtime_tests_#{System.pid()}@127.0.0.1")
      {:ok, _} = Node.start(name, :longnames)
      {:ok, _} = Application.ensure_all_started(:mirror_neuron)

      on_exit(fn ->
        Application.stop(:mirror_neuron)
        Node.stop()
        Application.ensure_all_started(:mirror_neuron)
      end)
    end

    :ok
  end

  # Fixed owner telemetry for admission tests. No native probe or GPU driver.
  def gpu_hardware do
    %{
      cpu: %{logical_processors: 4},
      memory: %{total_mb: 8192, available_mb: 8192},
      disk: %{total_mb: 16384, available_mb: 16384},
      devices: [
        %{
          id: "gpu-test",
          kind: "gpu",
          vendor: "nvidia",
          driver: "cuda",
          memory_total_mb: 10240,
          memory_free_mb: 10240
        }
      ]
    }
  end

  setup context do
    id = "runtime-test-#{System.pid()}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), id)
    namespace = String.replace(id, "-", "_")
    shared = Path.join(root, "shared")
    native = %{capabilities: ["resource_admission_v2"]}

    variables = %{
      "MN_REDIS_NAMESPACE" => namespace,
      "MN_RUNTIME_SHARED_STORAGE_ROOT" => shared,
      "MN_BUNDLE_CACHE_DIR" => Path.join(root, "bundles"),
      "MN_JOB_DATA_ROOT" => Path.join(root, "jobs"),
      "MN_NODE_HARDWARE_JSON" => Jason.encode!(%{native_sdk_grpc: native})
    }

    previous = Map.new(variables, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(variables)

    on_exit(fn ->
      try do
        {:ok, jobs} = RedisStore.list_jobs()
        Enum.each(jobs, &MirrorNeuron.Runtime.terminate_local_job(&1["job_id"]))

        {:ok, keys} = Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"])
        if keys != [], do: Redix.command!(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      after
        Enum.each(previous, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        Hardware.clear_snapshot()
        File.rm_rf!(root)
      end
    end)

    hardware = gpu_hardware()
    hardware = if context[:mock_gpu], do: hardware, else: Map.delete(hardware, :devices)
    Hardware.update_snapshot(Map.put(hardware, :native_sdk_grpc, native))

    {:ok, store} = RedisStore.coordination_store_status()

    {:ok, _} =
      NodeState.mark(Node.self(), "healthy", %{
        "scheduling_eligible" => true,
        "coordination_store" => store
      })

    {:ok, id: id, root: root, shared: shared}
  end
end
