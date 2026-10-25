defmodule MirrorNeuron.Runtime.SubmissionReadinessIntegrationTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus

  defmodule Runner do
    def run(payload, _config, opts) do
      send(:persistent_term.get({__MODULE__, :test}), {
        :input_executed,
        Keyword.fetch!(opts, :job_id),
        payload
      })

      {:ok,
       %{
         "exit_code" => 0,
         "stdout" => Jason.encode!(%{"complete_run" => %{"ok" => true}}),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  setup_all do
    # Admission uses an actual runtime identity, including in an unmanaged Mix
    # VM. Keep the single test node local and restore an unnamed VM afterward.
    unless Node.alive?() do
      :ok = Application.stop(:mirror_neuron)
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = String.to_atom("input_sync_tests_#{System.pid()}@127.0.0.1")
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

  setup do
    id = "input-sync-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), id)
    namespace = String.replace(id, "-", "_")

    variables = %{
      "MN_REDIS_NAMESPACE" => namespace,
      "MN_RUNTIME_SHARED_STORAGE_ROOT" => Path.join(root, "shared"),
      "MN_BUNDLE_CACHE_DIR" => Path.join(root, "bundles"),
      "MN_JOB_DATA_ROOT" => Path.join(root, "jobs"),
      "MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS" => "1800",
      "MN_NODE_HARDWARE_JSON" =>
        Jason.encode!(%{"native_sdk_grpc" => %{"capabilities" => ["resource_admission_v2"]}})
    }

    previous = Map.new(variables, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(variables)

    MirrorNeuron.Cluster.Hardware.update_snapshot(%{
      native_sdk_grpc: %{capabilities: ["resource_admission_v2"]},
      cpu: %{logical_processors: 4},
      memory: %{total_mb: 8192, available_mb: 8192},
      disk: %{total_mb: 16384, available_mb: 16384}
    })

    :persistent_term.put({Runner, :test}, self())
    {:ok, coordination_store} = RedisStore.coordination_store_status()

    {:ok, _} =
      MirrorNeuron.Cluster.NodeState.mark(Node.self(), "healthy", %{
        "scheduling_eligible" => true,
        "coordination_store" => coordination_store
      })

    on_exit(fn ->
      {:ok, jobs} = RedisStore.list_jobs()
      Enum.each(jobs, &Runtime.terminate_local_job(&1["job_id"]))

      case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
        {:ok, []} -> :ok
        {:ok, keys} -> Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      end

      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      :persistent_term.erase({Runner, :test})
      MirrorNeuron.Cluster.Hardware.clear_snapshot()
      File.rm_rf!(root)
    end)

    contents = "verified input\n"
    relative = "documents/source.txt"
    inputs = Path.join([variables["MN_RUNTIME_SHARED_STORAGE_ROOT"], "submissions", id, "inputs"])

    marker =
      Jason.encode!(%{
        "version" => "mn.input_readiness/v1",
        "files" => [
          %{"path" => relative, "size_bytes" => byte_size(contents), "sha256" => sha256(contents)}
        ],
        "file_count" => 1,
        "total_bytes" => byte_size(contents)
      })

    descriptor = %{
      "version" => "mn.input_readiness/v1",
      "path" => "inputs/.mn-inputs-ready.json",
      "sha256" => sha256(marker),
      "size_bytes" => byte_size(marker),
      "file_count" => 1,
      "total_bytes" => byte_size(contents)
    }

    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "input_sync_regression",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"source" => "staged"}]},
      "metadata" => %{
        "mn_storage" => %{"submission_id" => id, "inputs" => %{"readiness" => descriptor}}
      },
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root_coordinator",
            "config" => %{"runner_module" => Runner, "output_message_type" => nil}
          }
        ],
        "edges" => []
      }
    }

    {:ok,
     id: id,
     root: root,
     inputs: inputs,
     input_path: Path.join(inputs, relative),
     marker_path: Path.join(inputs, ".mn-inputs-ready.json"),
     marker: marker,
     contents: contents,
     manifest: manifest}
  end

  test "accepted stable-job launch waits through missing and partial replication, then executes once",
       ctx do
    assert {:ok, run_id, _} = start(ctx)
    assert_receive {:mirror_neuron_event, %{type: :submission_storage_waiting}}, 5_000
    pid = coordinator(run_id)
    assert_pending(pid, run_id)

    # The inventory can arrive before its files, and partially copied files can
    # have either the wrong length or the right length with the wrong digest.
    File.mkdir_p!(Path.dirname(ctx.input_path))
    File.write!(ctx.marker_path, ctx.marker)
    check_storage(pid)
    assert_pending(pid, run_id)

    File.write!(ctx.input_path, "partial")
    check_storage(pid)
    assert_pending(pid, run_id)

    File.write!(ctx.input_path, String.duplicate("x", byte_size(ctx.contents)))
    check_storage(pid)
    assert_pending(pid, run_id)

    File.write!(ctx.input_path, ctx.contents)
    # Leave the real readiness timer to continue automatically after replication.
    assert_receive {:mirror_neuron_event, %{type: :submission_storage_ready}}, 5_000
    assert_receive {:input_executed, ^run_id, %{"source" => "staged"}}, 5_000
    assert_receive {:mirror_neuron_event, %{type: :job_completed}}, 5_000
    assert {:ok, %{"status" => "completed"}} = RedisStore.fetch_job(run_id)
    refute_receive {:input_executed, ^run_id, _}
  end

  for restart <- [false, true] do
    @tag restart_admission: restart
    test "a queued launch starts automatically after cleanup (restart=#{restart})", ctx do
      assert {:ok, first, _} = start(ctx)
      assert_receive {:mirror_neuron_event, %{type: :submission_storage_waiting}}, 5_000
      old_pid = coordinator(first)
      old_token = :sys.get_state(old_pid).submission_storage.timer_token

      next = %{ctx | id: ctx.id <> "-next"}
      assert {:ok, second, nil} = start(next, admission_policy: "enqueue_if_busy")
      assert {:ok, %{"status" => "queued"}} = RedisStore.fetch_job(second)

      if ctx.restart_admission do
        :ok =
          Supervisor.terminate_child(MirrorNeuron.Supervisor, MirrorNeuron.Runtime.NodeAdmission)

        assert {:ok, _} =
                 Supervisor.restart_child(
                   MirrorNeuron.Supervisor,
                   MirrorNeuron.Runtime.NodeAdmission
                 )
      end

      assert {:ok, "cancelled"} = Runtime.cancel_job(first)

      # The running admission service must dispatch automatically after cleanup;
      # an explicit reconcile call here would hide a broken wake/timer path.
      assert_receive {:mirror_neuron_event,
                      %{type: :submission_storage_waiting, job_id: ^second}},
                     5_000

      assert_pending(coordinator(second), second)
      stage_inputs(ctx)
      send(old_pid, {:submission_storage_check, old_token})

      assert_receive {:input_executed, ^second, _}, 5_000
      assert_receive {:mirror_neuron_event, %{type: :job_completed, job_id: ^second}}, 5_000
      assert {:ok, %{"status" => "cancelled"}} = RedisStore.fetch_job(first)
      refute_receive {:input_executed, ^first, _}
      refute_receive {:input_executed, ^second, _}
    end
  end

  test "files arriving before a missing or partial inventory also wait and continue automatically",
       ctx do
    File.mkdir_p!(Path.dirname(ctx.input_path))
    File.write!(ctx.input_path, ctx.contents)
    assert {:ok, run_id, _} = start(ctx)
    assert_receive {:mirror_neuron_event, %{type: :submission_storage_waiting}}, 5_000
    pid = coordinator(run_id)
    assert_pending(pid, run_id)

    File.write!(ctx.marker_path, "partial inventory")
    check_storage(pid)
    assert_pending(pid, run_id)

    File.write!(ctx.marker_path, ctx.marker)
    assert_receive {:mirror_neuron_event, %{type: :submission_storage_ready}}, 5_000
    assert_receive {:input_executed, ^run_id, _}, 5_000
    assert_receive {:mirror_neuron_event, %{type: :job_completed}}, 5_000
    refute_receive {:input_executed, ^run_id, _}
  end

  test "missing inputs fail at the configured deadline with the storage diagnostic", ctx do
    System.put_env("MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS", "0")
    assert {:ok, run_id, _} = start(ctx)
    assert_receive {:mirror_neuron_event, %{type: :submission_storage_timeout}}, 5_000
    assert_receive {:mirror_neuron_event, %{type: :job_failed}}, 5_000
    assert {:ok, %{"status" => "failed", "result" => result}} = RedisStore.fetch_job(run_id)
    assert get_in(result, ["error", "details", "message"]) =~ "staged inputs were not ready"
    refute_receive {:input_executed, ^run_id, _}
  end

  test "invalid readiness metadata fails with its actual reason before executing", ctx do
    manifest =
      put_in(
        ctx.manifest,
        ["metadata", "mn_storage", "inputs", "readiness", "path"],
        "../outside"
      )

    assert {:ok, run_id, _} = start(%{ctx | manifest: manifest})
    assert_receive {:mirror_neuron_event, %{type: :job_failed}}, 5_000
    assert {:ok, %{"status" => "failed", "result" => result}} = RedisStore.fetch_job(run_id)

    assert get_in(result, ["error", "details", "message"]) ==
             "invalid_submission_readiness_descriptor"

    refute_receive {:input_executed, ^run_id, _}
  end

  test "already synchronized inputs start immediately without a waiting event", ctx do
    stage_inputs(ctx)
    assert {:ok, run_id, _} = start(ctx)
    assert_receive {:input_executed, ^run_id, _}, 5_000
    assert_receive {:mirror_neuron_event, %{type: :job_completed}}, 5_000
    refute_receive {:mirror_neuron_event, %{type: :submission_storage_waiting}}
    refute_receive {:input_executed, ^run_id, _}
  end

  defp start(ctx, options \\ []) do
    bundle = Path.join(ctx.root, ctx.id <> "-bundle")
    File.mkdir_p!(Path.join(bundle, "payloads"))
    File.write!(Path.join(bundle, "manifest.json"), Jason.encode!(ctx.manifest))
    {:ok, definition} = MirrorNeuron.create_job(bundle, job_id: "job-" <> ctx.id)
    EventBus.subscribe(ctx.id)
    MirrorNeuron.start_run(definition["job_id"], Keyword.merge([run_id: ctx.id], options))
  end

  defp stage_inputs(ctx) do
    File.mkdir_p!(Path.dirname(ctx.input_path))
    File.write!(ctx.input_path, ctx.contents)
    File.write!(ctx.marker_path, ctx.marker)
  end

  defp coordinator(run_id) do
    [{pid, _}] = Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, run_id})
    pid
  end

  defp assert_pending(pid, run_id) do
    assert :sys.get_state(pid).status == "pending"
    assert {:ok, %{"status" => "pending"}} = RedisStore.fetch_job(run_id)
    refute_receive {:input_executed, ^run_id, _}, 0
  end

  defp check_storage(pid) do
    state = :sys.get_state(pid)
    send(pid, {:submission_storage_check, state.submission_storage.timer_token})
    :sys.get_state(pid)
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
