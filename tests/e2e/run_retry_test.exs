defmodule MirrorNeuron.Runtime.RunRetryIntegrationTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.{Manifest, Message}
  alias MirrorNeuron.Artifacts.{SharedStorage, StagedArtifact}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{RunRetry, WorkflowLedger}

  defmodule RetryRunner do
    def run(payload, config, opts) do
      retry = Jason.decode!(config["environment"]["MN_RUN_RETRY_JSON"])
      {:ok, record} = RedisStore.fetch_job(Keyword.fetch!(opts, :job_id))

      send(
        :persistent_term.get({__MODULE__, :test}),
        {:active_identity, record["workflow_run_id"]}
      )

      send(
        :persistent_term.get({__MODULE__, :test}),
        {:executed, Keyword.fetch!(opts, :agent_id), Map.put(payload, "retry_context", retry)}
      )

      {:ok,
       %{
         "exit_code" => 0,
         "stdout" => Jason.encode!(%{"complete_step" => %{"recovered" => true}}),
         "stderr" => "",
         "logs" => ""
       }}
    end
  end

  setup do
    :persistent_term.put({RetryRunner, :test}, self())
    id = "checkpoint-test-#{System.unique_integer([:positive])}"

    raw = %{
      "manifest_version" => "1.0",
      "graph_id" => "checkpoint_test",
      "entrypoints" => ["done", "work"],
      "nodes" =>
        Enum.map(["done", "work"], fn node ->
          %{
            "node_id" => node,
            "agent_type" => "executor",
            "config" => %{
              "runner_module" => "MirrorNeuron.Runtime.RunRetryIntegrationTest.RetryRunner",
              "idempotent" => true,
              "output_message_type" => "worker_result"
            }
          }
        end) ++
          [
            %{
              "node_id" => "sink",
              "agent_type" => "aggregator",
              "config" => %{
                "complete_on_message" => true,
                "terminal_sink" => true,
                "complete_run" => true
              }
            }
          ],
      "edges" => [
        %{"from_node" => "work", "to_node" => "sink", "message_type" => "worker_result"}
      ],
      "flow" => %{
        "steps" => Enum.map(["done", "work"], &%{"id" => &1, "run" => &1}),
        "graph" => %{"edges" => []}
      }
    }

    raw =
      raw
      |> Map.put("apiVersion", "mn.workflow/v1")
      |> Map.put("kind", "Workflow")
      |> put_in(["flow", "nodes"], raw["nodes"])
      |> put_in(["flow", "edges"], raw["edges"])
      |> Map.drop(["nodes", "edges"])

    {:ok, manifest} = Manifest.load(raw)

    {ledger, _} =
      WorkflowLedger.new(manifest, manifest.nodes, nil, id) |> WorkflowLedger.job_running()

    message = Message.new(id, "runtime", "work", "init", %{"original" => true})
    {ledger, _} = WorkflowLedger.on_message_received(ledger, "work", message)

    ledger =
      ledger
      |> put_in(["steps", "done", "status"], "completed")
      |> put_in(["steps", "done", "output"], %{"saved" => true})
      |> put_in(["steps", "work", "status"], "failed")

    {:ok, lease} = RedisStore.acquire_fenced_lease("job:#{id}", "old", 60000)
    :ok = RedisStore.release_fenced_lease("job:#{id}", "old", lease["epoch"])

    {:ok, job} =
      RedisStore.persist_job(id, %{
        "job_id" => id,
        "run_id" => id,
        "status" => "failed",
        "attempt" => 1,
        "attempt_id" => "#{id}:1",
        "lease_epoch" => lease["epoch"],
        "manifest" => Manifest.to_map(manifest),
        "inputs" => manifest.initial_inputs || %{},
        "workflow_state" => ledger,
        "updated_at" => MirrorNeuron.Runtime.timestamp()
      })

    checkpoint = RunRetry.checkpoint(job, ledger)
    :ok = RedisStore.persist_run_checkpoint(id, checkpoint, lease["epoch"])

    on_exit(fn ->
      MirrorNeuron.cancel(id)
      RedisStore.delete_job(id)
      :persistent_term.erase({RetryRunner, :test})
    end)

    {:ok, id: id, job: job, checkpoint: checkpoint, manifest: manifest}
  end

  test "verified retry preserves completed work and duplicate submissions return the same attempt",
       ctx do
    MirrorNeuron.Runtime.EventBus.subscribe(ctx.id)
    assert {:ok, plan} = RunRetry.plan(ctx.id)
    assert plan["eligible"]
    assert plan["preserved_steps"] == ["done"]

    request = %{
      "expected_attempt" => 1,
      "checkpoint_revision" => plan["checkpoint_revision"],
      "idempotency_key" => "retry-1",
      "configuration_overrides" => %{}
    }

    requests = for _ <- 1..2, do: Task.async(fn -> RunRetry.submit(ctx.id, request) end)
    [first, second] = Enum.map(requests, &Task.await(&1, 15000))
    assert {:ok, receipt} = first
    assert second == first
    assert receipt["attempt"] == 2
    assert_receive {:active_identity, workflow_run_id}, 10000
    assert workflow_run_id == ctx.checkpoint["workflow"]["run_id"]

    assert_receive {:executed, "work",
                    %{"retry_context" => %{"active_since" => anchor, "attempt" => 2}}},
                   10000

    assert is_binary(anchor)
    refute_receive {:executed, "done", _}, 100
    refute_receive {:executed, "work", _}, 100
    assert {:ok, ^receipt} = RunRetry.submit(ctx.id, request)
    assert_receive {:mirror_neuron_event, %{type: :job_completed}}, 10000

    assert {:ok, %{"status" => "completed", "attempt" => 2} = completed} =
             RedisStore.fetch_job(ctx.id)

    assert completed["workflow_run_id"] == ctx.checkpoint["workflow"]["run_id"]
    assert {:ok, retained} = RedisStore.sweep_retention(terminal_job_ttl_seconds: 0)
    refute ctx.id in retained.deleted_jobs
    assert {:ok, _} = RedisStore.fetch_run_checkpoint(ctx.id)

    assert {:error, {:run_retry_blocked, _}} =
             RunRetry.submit(ctx.id, %{request | "configuration_overrides" => %{"changed" => 1}})
  end

  test "stale selection and writes are fenced; failed checkpoints outlive the retention sweep",
       ctx do
    assert {:error, {:run_retry_blocked, _}} =
             RunRetry.submit(ctx.id, %{
               "expected_attempt" => 1,
               "checkpoint_revision" => String.duplicate("a", 64),
               "idempotency_key" => "stale"
             })

    assert {:ok, result} = RedisStore.sweep_retention(terminal_job_ttl_seconds: 0)
    refute ctx.id in result.deleted_jobs
    assert {:ok, _} = RedisStore.fetch_run_checkpoint(ctx.id)
    assert {:ok, _} = RedisStore.persist_job(ctx.id, Map.put(ctx.job, "lease_epoch", 2))
    assert {:error, _} = RedisStore.persist_job(ctx.id, ctx.job)

    assert {:error, :stale_checkpoint_epoch} =
             RedisStore.persist_run_checkpoint(ctx.id, ctx.checkpoint, 1)

    assert {:ok, retained} = RedisStore.fetch_run_checkpoint(ctx.id)
    assert retained == ctx.checkpoint
  end

  test "a staged dependency skip reopens through the public retry contract", ctx do
    submission = Path.join([SharedStorage.root(), "submissions", ctx.id])

    {:ok, reference} =
      StagedArtifact.stage(%{"reason" => "trigger rule cannot be satisfied"},
        submission_id: ctx.id,
        submission_path: submission,
        run_id: ctx.id
      )

    ledger =
      ctx.checkpoint["workflow"]
      |> put_in(["steps", "work", "status"], "skipped")
      |> put_in(["steps", "work", "output_ref"], reference)

    {:ok, job} = RedisStore.persist_job(ctx.id, Map.put(ctx.job, "workflow_state", ledger))
    checkpoint = RunRetry.checkpoint(job, ledger)
    assert :ok = RedisStore.persist_run_checkpoint(ctx.id, checkpoint, 1)
    on_exit(fn -> File.rm_rf!(submission) end)

    assert {:ok, plan} = RunRetry.plan(ctx.id)
    assert plan["eligible"]
    assert plan["preserved_steps"] == ["done"]
    assert plan["retry_steps"] == ["work"]

    assert {:ok, %{"attempt" => 2}} =
             RunRetry.submit(ctx.id, %{
               "expected_attempt" => 1,
               "checkpoint_revision" => plan["checkpoint_revision"],
               "idempotency_key" => "retry-staged-skip"
             })

    assert_receive {:executed, "work", _}, 10000
    refute_receive {:executed, "done", _}, 100
  end

  test "changed immutable inputs and uncertain effects block before dispatch", ctx do
    assert {:ok, _} =
             RedisStore.persist_job(ctx.id, Map.put(ctx.job, "inputs", %{"changed" => true}))

    assert {:ok, %{"eligible" => false, "reason" => reason}} = RunRetry.plan(ctx.id)
    assert reason =~ "identity"

    manifest =
      put_in(ctx.job["manifest"], ["flow", "nodes", Access.at(1), "config", "idempotent"], false)

    {:ok, job} = RedisStore.persist_job(ctx.id, %{ctx.job | "manifest" => manifest})
    checkpoint = RunRetry.checkpoint(job, ctx.checkpoint["workflow"])
    assert :ok = RedisStore.persist_run_checkpoint(ctx.id, checkpoint, 1)
    assert {:ok, %{"eligible" => false, "reason" => reason}} = RunRetry.plan(ctx.id)
    assert reason =~ "Uncertain external effects"
  end

  test "malformed checkpoint and missing unfinished inputs block before dispatch", ctx do
    ledger = Map.delete(ctx.checkpoint["workflow"], "step_order")
    checkpoint = RunRetry.checkpoint(ctx.job, ledger)
    assert :ok = RedisStore.persist_run_checkpoint(ctx.id, checkpoint, 1)
    assert {:ok, %{"eligible" => false}} = RunRetry.plan(ctx.id)
    ledger = put_in(ctx.checkpoint["workflow"], ["steps", "work", "last_message"], nil)
    ledger = put_in(ledger, ["steps", "work", "last_message_ref"], nil)

    assert :ok =
             RedisStore.persist_run_checkpoint(ctx.id, RunRetry.checkpoint(ctx.job, ledger), 1)

    assert {:ok, %{"eligible" => false, "reason" => reason}} = RunRetry.plan(ctx.id)
    assert reason =~ "inputs are missing"
    refute_receive {:executed, _, _}
  end

  test "unstarted downstream work waits for its unfinished parent without a saved input", ctx do
    raw = Manifest.to_map(ctx.manifest)

    raw =
      raw
      |> update_in(["flow", "nodes"], fn nodes ->
        worker = Enum.find(nodes, &(&1["node_id"] == "work"))
        nodes ++ [Map.put(worker, "node_id", "publish")]
      end)
      |> update_in(["flow", "steps"], &(&1 ++ [%{"id" => "publish", "run" => "publish"}]))
      |> put_in(["flow", "graph", "edges"], [%{"from" => "work", "to" => "publish"}])

    {:ok, manifest} = Manifest.load(raw)
    ledger = WorkflowLedger.new(manifest, manifest.nodes, nil, ctx.id)

    ledger =
      ledger
      |> put_in(["steps", "done"], ctx.checkpoint["workflow"]["steps"]["done"])
      |> put_in(["steps", "work"], ctx.checkpoint["workflow"]["steps"]["work"])

    assert ledger["steps"]["publish"]["needs"] == nil
    assert ledger["steps"]["publish"]["last_message"] == nil

    {:ok, job} =
      RedisStore.persist_job(ctx.id, %{
        ctx.job
        | "manifest" => Manifest.to_map(manifest),
          "workflow_state" => ledger
      })

    assert :ok =
             RedisStore.persist_run_checkpoint(ctx.id, RunRetry.checkpoint(job, ledger), 1)

    assert {:ok, plan} = RunRetry.plan(ctx.id)
    assert plan["eligible"]
    assert plan["preserved_steps"] == ["done"]
    assert plan["retry_steps"] == ["work", "publish"]

    # An entrypoint still needs its original input even before its first attempt.
    root_without_input =
      ledger
      |> put_in(["steps", "work", "attempt_count"], 0)
      |> put_in(["steps", "work", "last_message"], nil)
      |> put_in(["steps", "work", "last_message_ref"], nil)

    assert :ok =
             RedisStore.persist_run_checkpoint(
               ctx.id,
               RunRetry.checkpoint(job, root_without_input),
               1
             )

    assert {:ok, %{"eligible" => false, "reason" => reason}} = RunRetry.plan(ctx.id)
    assert reason =~ "inputs are missing: work"
    refute_receive {:executed, _, _}
  end

  test "lingering coordinator cleanup blocks planning without consuming an attempt", ctx do
    assert {:ok, _} =
             Horde.Registry.register(MirrorNeuron.DistributedRegistry, {:job, ctx.id}, nil)

    assert {:ok, %{"eligible" => false, "reason" => reason}} = RunRetry.plan(ctx.id)
    assert reason =~ "cleanup"
    assert {:ok, %{"attempt" => 1}} = RedisStore.fetch_job(ctx.id)
    Horde.Registry.unregister(MirrorNeuron.DistributedRegistry, {:job, ctx.id})
  end

  test "invocation context refreshes preserved usage and the active clock after admission", ctx do
    anchor = MirrorNeuron.Runtime.timestamp()

    running =
      ctx.job
      |> Map.put("status", "running")
      |> Map.put("attempt", 2)
      |> Map.put("clock_session", "retry-clock")
      |> Map.put("updated_at", "2026-09-01T00:00:00.000Z")
      |> Map.put("retry_request", %{
        "effective_configuration_overrides" => %{"catalog_review.walltime_seconds" => 3600}
      })

    assert {:ok, _} = RedisStore.persist_job(ctx.id, running)

    assert {:ok, _} =
             RedisStore.persist_job(
               ctx.id,
               running
               |> Map.put("status", "paused")
               |> Map.put("updated_at", "2026-09-01T00:20:00.000Z")
             )

    assert {:ok, _} =
             RedisStore.persist_job(
               ctx.id,
               running
               |> Map.put("status", "pending")
               |> Map.put("updated_at", "2026-09-02T00:20:00.000Z")
             )

    running = Map.put(running, "updated_at", anchor)
    assert {:ok, _} = RedisStore.persist_job(ctx.id, running)

    config = %{
      "environment" => %{
        "MN_RUN_RETRY_JSON" => Jason.encode!(%{"consumed_seconds" => 0, "active_since" => nil}),
        "ORIGINAL_INPUT" => "unchanged"
      }
    }

    assert {:ok, refreshed} =
             RunRetry.invocation_config(config, %{job_id: ctx.id, lease_epoch: 1})

    assert Jason.decode!(refreshed["environment"]["MN_RUN_RETRY_JSON"]) == %{
             "consumed_seconds" => 1200.0,
             "active_since" => anchor,
             "attempt" => 2,
             "configuration_overrides" => %{"catalog_review.walltime_seconds" => 3600}
           }

    assert refreshed["environment"]["ORIGINAL_INPUT"] == "unchanged"

    for status <- ["pending", "paused", "failed"] do
      assert {:ok, _} = RedisStore.persist_job(ctx.id, Map.put(running, "status", status))

      assert {:error, %{"retryable" => false}} =
               RunRetry.invocation_config(config, %{job_id: ctx.id, lease_epoch: 1})
    end

    assert {:ok, _} = RedisStore.persist_job(ctx.id, Map.put(running, "lease_epoch", 2))

    assert {:error, %{"retryable" => false}} =
             RunRetry.invocation_config(config, %{job_id: ctx.id, lease_epoch: 1})

    assert {:error, %{"retryable" => false}} =
             RunRetry.invocation_config(config, %{job_id: ctx.id, lease_epoch: nil})
  end

  test "ordinary invocations preserve their configuration without a retry control record" do
    config = %{"environment" => %{"ORIGINAL_INPUT" => "unchanged"}}
    assert {:ok, ^config} = RunRetry.invocation_config(config, %{job_id: "unknown"})
  end
end
