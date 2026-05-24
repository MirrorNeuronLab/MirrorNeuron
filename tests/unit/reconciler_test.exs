defmodule MirrorNeuron.Cluster.ReconcilerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.JobBundle

  @test_pid_name :reconciler_test_pid

  defmodule RedisStoreStub do
    def put_jobs(jobs), do: :persistent_term.put({__MODULE__, :jobs}, jobs)

    def put_agents(job_id, agents),
      do: :persistent_term.put({__MODULE__, :agents, job_id}, agents)

    def put_lease(job_id, lease), do: :persistent_term.put({__MODULE__, :lease, job_id}, lease)

    def put_evals(evals),
      do: :persistent_term.put({__MODULE__, :evals}, Map.new(evals, &{&1["eval_id"], &1}))

    def list_jobs, do: {:ok, :persistent_term.get({__MODULE__, :jobs}, [])}

    def fetch_job(job_id) do
      case Enum.find(
             :persistent_term.get({__MODULE__, :jobs}, []),
             &(Map.get(&1, "job_id") == job_id)
           ) do
        nil -> {:error, "job #{job_id} was not found"}
        job -> {:ok, job}
      end
    end

    def list_agents(job_id), do: {:ok, :persistent_term.get({__MODULE__, :agents, job_id}, [])}

    def get_lease("job:" <> job_id),
      do: {:ok, :persistent_term.get({__MODULE__, :lease, job_id}, nil)}

    def persist_recovery_eval(eval_id, eval) do
      eval = Map.put(eval, "eval_id", eval_id)
      evals = :persistent_term.get({__MODULE__, :evals}, %{})
      :persistent_term.put({__MODULE__, :evals}, Map.put(evals, eval_id, eval))
      send(Process.whereis(:reconciler_test_pid), {:eval_persisted, eval_id, eval})
      {:ok, eval}
    end

    def update_recovery_eval(eval_id, updates) do
      evals = :persistent_term.get({__MODULE__, :evals}, %{})
      eval = evals |> Map.get(eval_id, %{"eval_id" => eval_id}) |> Map.merge(updates)
      persist_recovery_eval(eval_id, eval)
    end

    def list_recovery_evals do
      {:ok, :persistent_term.get({__MODULE__, :evals}, %{}) |> Map.values()}
    end

    def persist_terminal_job(job_id, updates, defaults) do
      send(Process.whereis(:reconciler_test_pid), {:job_persisted, job_id, updates, defaults})
      {:ok, defaults |> Map.merge(updates) |> Map.put("job_id", job_id)}
    end

    def release_fenced_lease(lease_name, owner, epoch) do
      send(Process.whereis(:reconciler_test_pid), {:lease_released, lease_name, owner, epoch})
      :ok
    end
  end

  defmodule ResourceStore do
    def fetch_resource_limits, do: {:error, "not configured"}
  end

  defmodule EventBusStub do
    def publish(job_id, event) do
      send(Process.whereis(:reconciler_test_pid), {:event_published, job_id, event})
      {:ok, event}
    end
  end

  defmodule CoordinatorStub do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)
    def init(parent), do: {:ok, parent}

    def handle_call({:reschedule_agents, agent_ids, scheduler_plan, reason}, _from, parent) do
      send(parent, {:coordinator_rescheduled, agent_ids, scheduler_plan, reason})
      {:reply, {:ok, %{affected_agents: agent_ids, scheduler: scheduler_plan}}, parent}
    end
  end

  setup do
    previous_store = Application.get_env(:mirror_neuron, :resource_limits_store)
    Application.put_env(:mirror_neuron, :resource_limits_store, ResourceStore)

    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)
    RedisStoreStub.put_jobs([])
    RedisStoreStub.put_evals([])

    on_exit(fn ->
      if is_nil(previous_store) do
        Application.delete_env(:mirror_neuron, :resource_limits_store)
      else
        Application.put_env(:mirror_neuron, :resource_limits_store, previous_store)
      end

      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      :persistent_term.erase({RedisStoreStub, :jobs})
      :persistent_term.erase({RedisStoreStub, :evals})
    end)

    :ok
  end

  test "reschedules affected agents when coordinator is alive" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("agent-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("agent-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "agent-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert result.recovered == 1
    assert_receive {:coordinator_rescheduled, ["worker"], scheduler_plan, _reason}
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]
    assert_receive {:job_persisted, "agent-job", %{"policy_state" => policy_state}, _}
    assert get_in(policy_state, ["agents", "worker", "reschedule_attempts"]) == 1
    assert_receive {:job_persisted, "agent-job", %{"recovery_status" => "rescheduling"}, _}
    assert_receive {:job_persisted, "agent-job", %{"recovery_status" => "rescheduled"}, _}
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "complete"
    assert eval["trigger"] == "node_down"
    assert eval["attempt"] == 1
  end

  test "does not relocate node-scoped system allocations to a different node" do
    job =
      running_job("system-job")
      |> Map.put("job_type", "system")
      |> put_in(["scheduler", "job_type"], "system")
      |> put_in(["scheduler", "system_targets"], ["small@lab", "large@lab"])
      |> put_in(["scheduler", "placements"], [
        %{
          "agent_id" => "worker@small@lab",
          "source_agent_id" => "worker",
          "agent_type" => "executor",
          "node" => "small@lab",
          "system_target" => "small@lab",
          "resources" => %{"cpu_cores" => 1, "memory_mb" => 512, "disk_mb" => 0, "gpu_count" => 0}
        },
        %{
          "agent_id" => "worker@large@lab",
          "source_agent_id" => "worker",
          "agent_type" => "executor",
          "node" => "large@lab",
          "system_target" => "large@lab",
          "resources" => %{"cpu_cores" => 1, "memory_mb" => 512, "disk_mb" => 0, "gpu_count" => 0}
        }
      ])

    RedisStoreStub.put_jobs([job])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               lookup_coordinator: fn "system-job" -> {:ok, coordinator} end
             )

    assert result.blocked == 1
    assert_receive {:job_persisted, "system-job", %{"recovery_status" => "waiting_for_node"}, _}
    assert_receive {:event_published, "system-job", %{type: :job_node_scoped_recovery_waiting}}
    refute_received {:coordinator_rescheduled, _, _, _}
  end

  test "restarts whole job when failed node owns the job lease" do
    {:ok, bundle} = JobBundle.load(manifest())

    job =
      running_job("whole-job")
      |> Map.merge(%{
        "lease_owner" => "small@lab",
        "lease_epoch" => 7,
        "lease" => %{"owner_id" => "small@lab", "epoch" => 7}
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("whole-job", [agent_snapshot("worker")])

    starter = fn job_id, _bundle, opts ->
      send(self(), {:job_started, job_id, opts})
      :ok
    end

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               start_job_runner: starter,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert result.recovered == 1
    assert_receive {:lease_released, "job:whole-job", "small@lab", 7}
    assert_receive {:job_started, "whole-job", opts}
    assert opts[:scheduler_plan]["placements"] |> hd() |> Map.get("node") == "large@lab"
  end

  test "pauses affected jobs that are not cluster recoverable" do
    job = running_job("local-job") |> Map.put("recovery_policy", "local_restart")
    RedisStoreStub.put_jobs([job])

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub
             )

    assert result.paused == 1
    assert_receive {:job_persisted, "local-job", updates, _}
    assert updates["status"] == "paused"
    assert updates["recovery_status"] == "paused_for_review"
  end

  test "only_job_ids limits node reconciliation to selected jobs" do
    RedisStoreStub.put_jobs([
      running_job("selected") |> Map.put("recovery_policy", "local_restart"),
      running_job("ignored") |> Map.put("recovery_policy", "local_restart")
    ])

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               only_job_ids: ["selected"]
             )

    assert result.checked == 1
    assert [%{job_id: "selected"}] = result.jobs
    assert_receive {:job_persisted, "selected", _, _}
    refute_receive {:job_persisted, "ignored", _, _}
  end

  test "pauses cluster recoverable job when affected snapshot is missing" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("missing-snapshot")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("missing-snapshot", [])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "missing-snapshot" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert result.paused == 1
    assert_receive {:job_persisted, "missing-snapshot", updates, _}
    assert updates["status"] == "paused"
    assert updates["recovery_reason"] =~ "missing"
  end

  test "blocks recovery eval when no alternate placement exists" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("blocked-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("blocked-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "blocked-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node()], jobs: [job]],
               retry_base_ms: 10
             )

    assert result.blocked == 1
    assert_receive {:job_persisted, "blocked-job", updates, _}
    assert updates["recovery_status"] == "blocked_no_placement"
    assert updates["recovery_wait_until"]
    refute_received {:job_persisted, "blocked-job", %{"policy_state" => _policy_state}, _}
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "blocked"
    assert eval["attempt"] == 1
    refute_received {:coordinator_rescheduled, _, _, _}
  end

  test "pauses when reschedule policy is disabled" do
    {:ok, bundle} = JobBundle.load(manifest())

    job =
      running_job("policy-disabled")
      |> Map.put("reschedule_policy", %{
        "type" => "reschedule",
        "enabled" => true,
        "attempts" => 0,
        "interval_ms" => 86_400_000,
        "delay_ms" => 5_000,
        "delay_function" => "constant",
        "max_delay_ms" => 5_000,
        "unlimited" => false
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("policy-disabled", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "policy-disabled" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert result.paused == 1
    assert_receive {:job_persisted, "policy-disabled", updates, _}
    assert updates["status"] == "paused"
    assert updates["recovery_reason"] =~ "reschedule policy blocked"
    refute_received {:coordinator_rescheduled, _, _, _}
  end

  test "drain-triggered reschedule bypasses failure policy and does not consume attempts" do
    {:ok, bundle} = JobBundle.load(manifest())

    job =
      running_job("drain-policy-skip")
      |> Map.put("reschedule_policy", %{
        "type" => "reschedule",
        "enabled" => true,
        "attempts" => 0,
        "interval_ms" => 86_400_000,
        "delay_ms" => 5_000,
        "delay_function" => "constant",
        "max_delay_ms" => 5_000,
        "unlimited" => false
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("drain-policy-skip", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "drain-policy-skip" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               trigger: "node_drain",
               skip_reschedule_policy: true,
               skip_reschedule_policy_record: true
             )

    assert result.recovered == 1
    assert_receive {:coordinator_rescheduled, ["worker"], scheduler_plan, _reason}
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]

    assert_receive {:job_persisted, "drain-policy-skip", %{"recovery_status" => "rescheduling"},
                    _}

    assert_receive {:job_persisted, "drain-policy-skip", %{"recovery_status" => "rescheduled"}, _}
    refute_received {:job_persisted, "drain-policy-skip", %{"policy_state" => _policy_state}, _}
  end

  test "node drain whole-job recovery stops the live coordinator before restart" do
    {:ok, bundle} = JobBundle.load(manifest())

    job =
      running_job("drain-whole-job")
      |> Map.merge(%{
        "lease_owner" => "small@lab",
        "lease_epoch" => 9,
        "lease" => %{"owner_id" => "small@lab", "epoch" => 9}
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("drain-whole-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())
    monitor_ref = Process.monitor(coordinator)

    starter = fn job_id, _bundle, opts ->
      send(self(), {:job_started, job_id, opts})
      :ok
    end

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "drain-whole-job" -> {:ok, coordinator} end,
               start_job_runner: starter,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               trigger: "node_drain"
             )

    assert result.recovered == 1
    assert_receive {:DOWN, ^monitor_ref, :process, ^coordinator, :normal}
    assert_receive {:lease_released, "job:drain-whole-job", "small@lab", 9}
    assert_receive {:job_started, "drain-whole-job", opts}
    assert opts[:preferred_start_node] == "large@lab"
    assert opts[:scheduler_plan]["placements"] |> hd() |> Map.get("node") == "large@lab"
  end

  test "internal reschedule_agents recovers a specific agent after restart exhaustion" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("restart-exhausted")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("restart-exhausted", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reschedule_agents("restart-exhausted", ["worker"],
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "restart-exhausted" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               reason: "restart attempts exhausted"
             )

    assert result.recovered == 1
    assert_receive {:coordinator_rescheduled, ["worker"], scheduler_plan, reason}
    assert reason == "restart attempts exhausted"
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["trigger"] == "restart_exhausted"
    assert eval["status"] == "complete"
  end

  test "blocks recovery when final plan validation sees stale target node" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("validation-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("validation-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    stale_large_node = Map.put(large_node(), "status", "offline")

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "validation-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               validation_nodes: [small_node(), stale_large_node],
               retry_base_ms: 10
             )

    assert result.blocked == 1
    assert_receive {:job_persisted, "validation-job", updates, _}
    assert updates["recovery_status"] == "blocked_no_placement"
    assert updates["recovery_reason"] =~ "offline"
    refute_received {:coordinator_rescheduled, _, _, _}
  end

  test "waits during disconnected grace window" do
    job = running_job("grace-job")
    RedisStoreStub.put_jobs([job])
    wait_until = future_iso(60_000)

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               node_status: "disconnected",
               wait_until: wait_until
             )

    assert result.blocked == 1
    assert_receive {:job_persisted, "grace-job", updates, _}
    assert updates["recovery_status"] == "waiting_for_node"
    assert updates["recovery_wait_until"] == wait_until
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "blocked"
    assert eval["wait_until"] == wait_until
  end

  test "offline recovery reuses the disconnected grace eval" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("grace-recover-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("grace-recover-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, blocked_result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               node_status: "disconnected",
               wait_until: future_iso(60_000)
             )

    assert blocked_result.blocked == 1

    assert {:ok, [%{"eval_id" => eval_id, "status" => "blocked"}]} =
             RedisStoreStub.list_recovery_evals()

    assert {:ok, recovered_result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               node_status: "offline",
               force: true,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "grace-recover-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert recovered_result.recovered == 1
    assert_receive {:coordinator_rescheduled, ["worker"], _scheduler_plan, _reason}

    assert {:ok, [%{"eval_id" => ^eval_id, "status" => "complete"}]} =
             RedisStoreStub.list_recovery_evals()
  end

  test "wakes blocked evals after new capacity appears" do
    {:ok, bundle} = JobBundle.load(manifest())
    job = running_job("wake-job")
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("wake-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, blocked_result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "wake-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node()], jobs: [job]],
               retry_base_ms: 10
             )

    assert blocked_result.blocked == 1

    assert {:ok, wake_result} =
             Reconciler.wake_blocked_evals(
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "wake-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               retry_base_ms: 10,
               reason: "node joined"
             )

    assert wake_result.recovered == 1
    assert_receive {:coordinator_rescheduled, ["worker"], scheduler_plan, _reason}
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "complete"
    assert eval["attempt"] == 2
  end

  defp running_job(job_id) do
    %{
      "job_id" => job_id,
      "graph_id" => "reconcile-test",
      "job_name" => "reconcile-test",
      "status" => "running",
      "lease_owner" => "coordinator@lab",
      "recovery_policy" => "cluster_recover",
      "requested_recovery_policy" => "cluster_recover",
      "manifest_ref" => %{"bundle_storage" => "redis", "bundle_fingerprint" => "test"},
      "scheduler" => %{
        "job_type" => "service",
        "strategy" => "binpack",
        "placements" => [
          %{
            "agent_id" => "worker",
            "agent_type" => "executor",
            "node" => "small@lab",
            "resources" => %{
              "cpu_cores" => 1,
              "memory_mb" => 512,
              "disk_mb" => 0,
              "gpu_count" => 0
            }
          }
        ]
      }
    }
  end

  defp agent_snapshot(agent_id) do
    %{
      "agent_id" => agent_id,
      "node_id" => agent_id,
      "agent_type" => "executor",
      "mailbox_depth" => 0,
      "processed_messages" => 0,
      "pending_messages" => [],
      "metadata" => %{}
    }
  end

  defp manifest do
    %{
      "manifest_version" => "1.0",
      "graph_id" => "reconcile-test",
      "entrypoints" => ["worker"],
      "nodes" => [
        %{
          "node_id" => "worker",
          "agent_type" => "executor",
          "role" => "root",
          "resources" => %{"cpu_cores" => 1, "memory_mb" => 512},
          "config" => %{"safe_to_retry" => true}
        }
      ],
      "edges" => [],
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }
  end

  defp small_node do
    %{
      "name" => "small@lab",
      "status" => "healthy",
      "hardware" => %{
        "cpu" => %{"logical_processors" => 4},
        "memory" => %{"available_mb" => 4096},
        "disk" => %{"available_mb" => 100_000},
        "gpu" => "Unknown or None"
      }
    }
  end

  defp large_node do
    %{
      "name" => "large@lab",
      "status" => "healthy",
      "hardware" => %{
        "cpu" => %{"logical_processors" => 8},
        "memory" => %{"available_mb" => 16_384},
        "disk" => %{"available_mb" => 100_000},
        "gpu" => "Unknown or None"
      }
    }
  end

  defp future_iso(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(delay_ms, :millisecond)
    |> DateTime.to_iso8601()
  end
end
