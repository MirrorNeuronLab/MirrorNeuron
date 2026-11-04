defmodule MirrorNeuron.Runtime.SubmissionReadinessIntegrationTest do
  use MirrorNeuron.RuntimeCase, async: false

  @moduletag :blueprint_runtime

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

  setup %{id: id, shared: shared} do
    previous = System.get_env("MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS")
    System.put_env("MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS", "1800")
    :persistent_term.put({Runner, :test}, self())

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS", previous),
        else: System.delete_env("MN_SHARED_STORAGE_READY_TIMEOUT_SECONDS")

      :persistent_term.erase({Runner, :test})
    end)

    contents = "verified input\n"
    relative = "documents/source.txt"
    inputs = Path.join([shared, "submissions", id, "inputs"])

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
