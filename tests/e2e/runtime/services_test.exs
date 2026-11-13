defmodule MirrorNeuron.Runtime.ServicesTest do
  use MirrorNeuron.RuntimeExecutionCase, async: false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ServiceRegistry
  alias MirrorNeuron.RuntimeTest.FailOnceCounter
  alias MirrorNeuron.RuntimeTest.FailOnceServiceRunner
  alias MirrorNeuron.RuntimeTest.DelayedCompleteRunner
  alias MirrorNeuron.RuntimeTest.LongSleepRunner

  test "service jobs ignore task completion and keep the allocation running" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "service_completion_restart_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"work" => "stay up"}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => DelayedCompleteRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart", "job_type" => "service"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        {:ok, events} = MirrorNeuron.events(job_id)
        Enum.any?(events, &(&1["type"] == "service_agent_completed"))
      end,
      3_000
    )

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert job["job_type"] == "service"

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  test "service jobs recover retry-safe auxiliary command failures without replaying the job" do
    :ok = FailOnceCounter.init()

    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "graph_id" => "service_auxiliary_failure_recovery_test",
      "type" => "service",
      "entrypoints" => ["workflow_worker", "service_worker"],
      "initial_inputs" => %{
        "workflow_worker" => [%{"work" => "stay available"}],
        "service_worker" => [%{"work" => "serve requests"}]
      },
      "flow" => %{
        "steps" => [
          %{
            "id" => "workflow_worker",
            "run" => "workflow_worker",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 60,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 0}
            }
          }
        ],
        "graph" => %{"edges" => []}
      },
      "nodes" => [
        %{
          "node_id" => "workflow_worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => LongSleepRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        },
        %{
          "node_id" => "service_worker",
          "agent_type" => "executor",
          "config" => %{
            "runner_module" => FailOnceServiceRunner,
            "output_message_type" => nil,
            "safe_to_retry" => true
          }
        }
      ],
      "edges" => [],
      "policies" => %{
        "recovery_mode" => "local_restart",
        "restart" => %{
          "attempts" => 2,
          "interval_ms" => 60_000,
          "delay_ms" => 1,
          "delay_function" => "constant",
          "max_delay_ms" => 1,
          "mode" => "delay"
        }
      }
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    cleanup_job_on_exit(job_id)
    wait_until(fn -> FailOnceCounter.invocations() >= 2 end, 3_000)

    assert {:ok, job} = MirrorNeuron.inspect_job(job_id)
    assert job["status"] == "running"
    assert job["attempt"] == 1

    assert {:ok, events} = MirrorNeuron.events(job_id)
    assert Enum.any?(events, &(&1["type"] == "service_agent_failed"))
    assert Enum.any?(events, &(&1["type"] == "message_retry_scheduled"))
    refute Enum.any?(events, &(&1["type"] == "job_clean_restart_scheduled"))

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  test "service jobs register and deregister declared service instances" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "service_registry_runtime_test",
      "type" => "service",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "router",
          "role" => "root_coordinator",
          "resources" => %{
            "ports" => [
              %{"label" => "mcp-collaboration", "port" => "auto", "protocol" => "http"}
            ]
          },
          "services" => [
            %{
              "name" => "agent-api",
              "address" => "127.0.0.1",
              "port" => "${env.MN_PORT_MCP_COLLABORATION}",
              "tags" => ["runtime-test"],
              "meta" => %{
                "job_id" => "${env.MN_JOB_ID}",
                "run_id" => "${env.MN_RUN_ID}"
              }
            }
          ]
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    wait_until(fn -> running_status?(job_id) end, 2_000)

    wait_until(
      fn ->
        {:ok, services} = ServiceRegistry.resolve("agent-api", job_id: job_id)
        Enum.any?(services, &(&1["agent_id"] == "worker" and &1["status"] == "passing"))
      end,
      2_000
    )

    assert {:ok, [service]} = ServiceRegistry.resolve("agent-api", job_id: job_id)
    assert service["node"] == to_string(Node.self())
    assert service["tags"] == ["runtime-test"]
    assert service["port"] in 49_152..65_535
    assert service["meta"]["job_id"] == job_id
    assert service["meta"]["run_id"] == job_id

    assert {:ok, "paused"} = MirrorNeuron.pause(job_id)

    wait_until(
      fn ->
        {:ok, services} = ServiceRegistry.list(job_id: job_id, passing_only: false)
        services == []
      end,
      2_000
    )

    assert {:ok, "resumed"} = MirrorNeuron.resume(job_id)

    wait_until(
      fn ->
        {:ok, services} = ServiceRegistry.resolve("agent-api", job_id: job_id)
        Enum.any?(services, &(&1["agent_id"] == "worker" and &1["status"] == "passing"))
      end,
      2_000
    )

    assert {:ok, "cancelled"} = MirrorNeuron.cancel(job_id)

    wait_until(
      fn ->
        {:ok, services} = ServiceRegistry.list(job_id: job_id, passing_only: false)
        services == []
      end,
      2_000
    )

    RedisStore.delete_job(job_id)
  end

  test "sysbatch jobs complete after every eligible system target finishes once" do
    manifest = %{
      "manifest_version" => "1.0",
      "graph_id" => "sysbatch_completion_test",
      "entrypoints" => ["worker"],
      "initial_inputs" => %{"worker" => [%{"work" => "once per node"}]},
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root_coordinator",
          "config" => %{
            "runner_module" => DelayedCompleteRunner,
            "output_message_type" => nil
          }
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "local_restart", "job_type" => "sysbatch"}
    }

    assert {:ok, job_id} = run_manifest(manifest, await: false)
    assert {:ok, job} = MirrorNeuron.wait_for_job(job_id, 3_000)

    assert job["status"] == "completed"
    assert job["job_type"] == "sysbatch"
    assert get_in(job, ["scheduler", "system_count"]) == 1
    assert get_in(job, ["result", "completed_targets"]) == [to_string(Node.self())]
    assert map_size(get_in(job, ["result", "target_results"])) == 1

    RedisStore.delete_job(job_id)
  end
end
