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
    def clear_lease(job_id), do: :persistent_term.erase({__MODULE__, :lease, job_id})
    def raise_on_lease(job_id), do: :persistent_term.put({__MODULE__, :raise_lease, job_id}, true)

    def clear_raise_on_lease(job_id),
      do: :persistent_term.erase({__MODULE__, :raise_lease, job_id})

    def raise_on_fetch(job_id), do: :persistent_term.put({__MODULE__, :raise_fetch, job_id}, true)

    def clear_raise_on_fetch(job_id),
      do: :persistent_term.erase({__MODULE__, :raise_fetch, job_id})

    def put_evals(evals),
      do: :persistent_term.put({__MODULE__, :evals}, Map.new(evals, &{&1["eval_id"], &1}))

    def list_jobs, do: {:ok, :persistent_term.get({__MODULE__, :jobs}, [])}

    def list_job_summaries do
      jobs =
        :persistent_term.get({__MODULE__, :jobs}, [])
        |> Enum.map(fn job ->
          job
          |> Map.take([
            "job_id",
            "status",
            "job_type",
            "scheduler",
            "lease_owner",
            "lease",
            "updated_at",
            "submitted_at",
            "recovery_policy",
            "requested_recovery_policy",
            "restart_policy",
            "reschedule_policy",
            "policy_state",
            "recovery_status",
            "recovery_requires_review",
            "recovery_reason"
          ])
          |> Map.update("scheduler", nil, &scheduler_summary/1)
        end)

      {:ok, jobs}
    end

    defp scheduler_summary(%{"placements" => placements} = scheduler) do
      scheduler
      |> Map.take(["status", "job_type", "strategy", "mode", "placement_count"])
      |> Map.put(
        "nodes",
        placements
        |> Enum.map(&Map.get(&1, "node"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
      )
    end

    defp scheduler_summary(_scheduler), do: nil

    def fetch_job(job_id) do
      if :persistent_term.get({__MODULE__, :raise_fetch, job_id}, false) do
        raise "fetch backend exploded for #{job_id}"
      end

      case Enum.find(
             :persistent_term.get({__MODULE__, :jobs}, []),
             &(Map.get(&1, "job_id") == job_id)
           ) do
        nil -> {:error, "job #{job_id} was not found"}
        job -> {:ok, job}
      end
    end

    def list_agents(job_id), do: {:ok, :persistent_term.get({__MODULE__, :agents, job_id}, [])}

    def get_lease("job:" <> job_id) do
      if :persistent_term.get({__MODULE__, :raise_lease, job_id}, false) do
        raise "lease backend exploded for #{job_id}"
      end

      {:ok, :persistent_term.get({__MODULE__, :lease, job_id}, nil)}
    end

    def persist_recovery_eval(eval_id, eval) do
      eval =
        eval
        |> Map.drop(["job", :job])
        |> Map.put("eval_id", eval_id)

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

    def list_recovery_evals(statuses) do
      statuses = MapSet.new(Enum.map(List.wrap(statuses), &to_string/1))

      evals =
        :persistent_term.get({__MODULE__, :evals}, %{})
        |> Map.values()
        |> Enum.filter(&(Map.get(&1, "status") in statuses))

      {:ok, evals}
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

  test "restarts a clean job attempt when an affected agent's node is lost" do
    {:ok, bundle} = JobBundle.load(manifest())

    job =
      running_job("agent-job")
      |> Map.merge(%{
        "run_id" => "agent-job",
        "stable_job_id" => "stable-agent-job",
        "job_data_dir" => "/var/lib/mirror-neuron/job-data/stable-agent-job",
        "job_data_access" => "read_write",
        "data_generation" => 3
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("agent-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "agent-job" -> {:ok, coordinator} end,
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert result.recovered == 1
    assert_receive {:job_started, "agent-job", opts}
    scheduler_plan = opts[:scheduler_plan]
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]
    assert opts[:restart_reason] =~ "restarting the whole job attempt"
    assert opts[:run_id] == "agent-job"
    assert opts[:stable_job_id] == "stable-agent-job"
    assert opts[:job_data_dir] == "/var/lib/mirror-neuron/job-data/stable-agent-job"
    assert opts[:job_data_access] == "read_write"
    assert opts[:data_generation] == 3
    refute_received {:coordinator_rescheduled, _, _, _}
    assert_receive {:job_persisted, "agent-job", %{"policy_state" => policy_state}, _}
    assert get_in(policy_state, ["agents", "worker", "reschedule_attempts"]) == 1
    assert_receive {:job_persisted, "agent-job", %{"recovery_status" => "rescheduling"}, _}
    assert_receive {:job_persisted, "agent-job", %{"recovery_status" => "rescheduled"}, _}
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "complete"
    assert eval["trigger"] == "node_down"
    assert eval["attempt"] == 1
  end

  test "loads shared filesystem CAS bundle references during recovery" do
    root = shared_bundle_root()

    job =
      running_job("shared-cas-job")
      |> put_in(["manifest_ref"], %{
        "bundle_storage" => "shared_fs_cas",
        "bundle_fingerprint" => "shared-cas-fingerprint",
        "cache_path" => root
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("shared-cas-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               lookup_coordinator: fn "shared-cas-job" -> {:ok, coordinator} end,
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert result.recovered == 1
    assert_receive {:job_started, "shared-cas-job", opts}
    scheduler_plan = opts[:scheduler_plan]
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]
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

  test "node reconciliation skips unaffected summaries without fetching full jobs" do
    job_id = unique_job_id("unaffected-job")
    job = running_job(job_id)
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.raise_on_fetch(job_id)

    on_exit(fn -> RedisStoreStub.clear_raise_on_fetch(job_id) end)

    assert {:ok, result} =
             Reconciler.reconcile_node("other@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub
             )

    assert result.checked == 1
    assert result.skipped == 1
    assert [%{job_id: ^job_id, action: :skipped}] = result.jobs
  end

  test "restarts cluster recoverable job without an agent snapshot" do
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
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert result.recovered == 1
    assert_receive {:job_started, "missing-snapshot", opts}
    assert opts[:preferred_start_node] == "large@lab"
    refute_received {:job_persisted, "missing-snapshot", %{"status" => "paused"}, _}
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
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               trigger: "node_drain",
               skip_reschedule_policy: true,
               skip_reschedule_policy_record: true
             )

    assert result.recovered == 1
    assert_receive {:job_started, "drain-policy-skip", opts}
    scheduler_plan = opts[:scheduler_plan]
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

  test "internal reschedule_agents starts a clean attempt after restart exhaustion" do
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
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               reason: "restart attempts exhausted"
             )

    assert result.recovered == 1
    assert_receive {:job_started, "restart-exhausted", opts}
    scheduler_plan = opts[:scheduler_plan]
    assert opts[:restart_reason] =~ "restart attempts exhausted"
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["trigger"] == "restart_exhausted"
    assert eval["status"] == "complete"
  end

  test "due eval sweep ignores completed recovery eval history" do
    RedisStoreStub.put_evals([
      %{
        "eval_id" => "complete-eval",
        "job_id" => "finished-job",
        "trigger" => "lease_lost",
        "status" => "complete",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-01T00:00:00Z",
        "job" => running_job("finished-job")
      }
    ])

    assert {:ok, result} = Reconciler.process_due_evals(redis_store: RedisStoreStub)
    assert result.checked == 0
    assert result.skipped == 0
  end

  test "due eval sweep marks eval failed when processing raises" do
    job_id = unique_job_id("eval-fetch-crash-job")
    eval_id = "eval-fetch-crash"

    RedisStoreStub.put_evals([
      %{
        "eval_id" => eval_id,
        "job_id" => job_id,
        "trigger" => "lease_lost",
        "status" => "pending",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-01T00:00:00Z"
      }
    ])

    RedisStoreStub.raise_on_fetch(job_id)
    on_exit(fn -> RedisStoreStub.clear_raise_on_fetch(job_id) end)

    assert {:ok, result} = Reconciler.process_due_evals(redis_store: RedisStoreStub)

    assert result.checked == 1
    assert result.failed == 1
    assert [%{job_id: ^job_id, action: :failed, reason: reason}] = result.jobs
    assert reason =~ "recovery eval #{eval_id} exception"
    assert reason =~ "fetch backend exploded"

    assert_receive {:eval_persisted, ^eval_id, %{"status" => "running"}}
    assert_receive {:eval_persisted, ^eval_id, %{"status" => "failed"} = failed_eval}
    assert failed_eval["completed_at"]
    assert [%{"status" => "failed", "reason" => failed_reason}] = failed_eval["history"]
    assert failed_reason =~ "fetch backend exploded"
  end

  test "orphan sweep skips active job lease without persisting recovery eval" do
    job_id = unique_job_id("leased-job")
    job = running_job(job_id)
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_lease(job_id, %{"owner_id" => "coordinator@lab", "epoch" => 3})
    on_exit(fn -> RedisStoreStub.clear_lease(job_id) end)

    assert {:ok, result} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    assert result.checked == 1
    assert result.skipped == 1

    assert [%{job_id: ^job_id, action: :skipped, reason: "job lease is still active"}] =
             result.jobs

    assert {:ok, []} = RedisStoreStub.list_recovery_evals()
    refute_received {:eval_persisted, _, _}
  end

  test "orphan sweep delegates local restart jobs without creating a cluster recovery eval" do
    job_id = unique_job_id("orphan-job")

    job =
      running_job(job_id)
      |> Map.put("recovery_policy", "local_restart")
      |> Map.put("manifest", %{
        "graph_id" => "large-manifest",
        "payload" => String.duplicate("x", 1024)
      })

    RedisStoreStub.put_jobs([job])

    assert {:ok, result} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    assert result.checked == 1
    assert result.skipped == 1

    assert [%{job_id: ^job_id, action: :skipped, reason: "job is managed by local recovery"}] =
             result.jobs

    assert {:ok, []} = RedisStoreStub.list_recovery_evals()
    refute_received {:eval_persisted, _, _}
    refute_received {:job_persisted, ^job_id, _, _}
  end

  test "repeated orphan sweeps with active lease do not create eval churn" do
    job_id = unique_job_id("stable-lease-job")
    job = running_job(job_id)
    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_lease(job_id, %{"owner_id" => "coordinator@lab", "epoch" => 4})
    on_exit(fn -> RedisStoreStub.clear_lease(job_id) end)

    assert {:ok, first} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)
    assert {:ok, second} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    assert first.skipped == 1
    assert second.skipped == 1
    assert {:ok, []} = RedisStoreStub.list_recovery_evals()
    refute_received {:eval_persisted, _, _}
  end

  test "repeated orphan sweeps do not reread or reevaluate jobs paused for review" do
    job_id = unique_job_id("paused-review-job")

    job =
      running_job(job_id)
      |> Map.merge(%{
        "status" => "paused",
        "recovery_status" => "paused_for_review",
        "recovery_requires_review" => true
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.raise_on_lease(job_id)
    RedisStoreStub.raise_on_fetch(job_id)

    on_exit(fn ->
      RedisStoreStub.clear_raise_on_lease(job_id)
      RedisStoreStub.clear_raise_on_fetch(job_id)
    end)

    assert {:ok, first} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)
    assert {:ok, second} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    for result <- [first, second] do
      assert result.checked == 1
      assert result.skipped == 1

      assert [%{job_id: ^job_id, action: :skipped, reason: "job is paused for review"}] =
               result.jobs
    end

    assert {:ok, []} = RedisStoreStub.list_recovery_evals()
    refute_received {:eval_persisted, _, _}
  end

  test "node reconciliation does not load paused-for-review job snapshots" do
    job_id = unique_job_id("paused-node-job")

    job =
      running_job(job_id)
      |> Map.merge(%{
        "status" => "paused",
        "recovery_status" => "paused_for_review",
        "recovery_requires_review" => true
      })

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.raise_on_fetch(job_id)
    on_exit(fn -> RedisStoreStub.clear_raise_on_fetch(job_id) end)

    assert {:ok, result} =
             Reconciler.reconcile_node("small@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub
             )

    assert result.checked == 1
    assert result.skipped == 1

    assert [%{job_id: ^job_id, action: :skipped, reason: "job is paused for review"}] =
             result.jobs

    refute_received {:job_persisted, ^job_id, _, _}
    refute_received {:event_published, ^job_id, _}
  end

  test "orphan sweep isolates per-job lease exceptions and continues" do
    crashing_job_id = unique_job_id("crashing-lease-job")
    stable_job_id = unique_job_id("stable-after-crash-job")

    RedisStoreStub.put_jobs([running_job(crashing_job_id), running_job(stable_job_id)])
    RedisStoreStub.raise_on_lease(crashing_job_id)
    RedisStoreStub.put_lease(stable_job_id, %{"owner_id" => "coordinator@lab", "epoch" => 8})

    on_exit(fn ->
      RedisStoreStub.clear_raise_on_lease(crashing_job_id)
      RedisStoreStub.clear_lease(stable_job_id)
    end)

    assert {:ok, result} = Reconciler.sweep_orphaned_jobs(nil, redis_store: RedisStoreStub)

    assert result.checked == 2
    assert result.failed == 1
    assert result.skipped == 1

    failed_result = Enum.find(result.jobs, &(&1.job_id == crashing_job_id))
    assert failed_result.action == :failed
    assert failed_result.reason =~ "orphan sweep exception"
    assert failed_result.reason =~ "lease backend exploded"

    assert Enum.find(result.jobs, &(&1.job_id == stable_job_id)).action == :skipped
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
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]]
             )

    assert recovered_result.recovered == 1
    assert_receive {:job_started, "grace-recover-job", opts}
    assert opts[:preferred_start_node] == "large@lab"

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
               start_job_runner: job_starter(self()),
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               retry_base_ms: 10,
               reason: "node joined"
             )

    assert wake_result.recovered == 1
    assert_receive {:job_started, "wake-job", opts}
    scheduler_plan = opts[:scheduler_plan]
    assert [%{"agent_id" => "worker", "node" => "large@lab"}] = scheduler_plan["placements"]
    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "complete"
    assert eval["attempt"] == 2
  end

  test "GPU recovery stays blocked on CPU-only nodes and resumes on a rejoined GPU node with a new name" do
    {:ok, bundle} = JobBundle.load(gpu_manifest())

    job =
      running_job("gpu-wake-job")
      |> put_in(["scheduler", "placements"], [
        %{
          "agent_id" => "worker",
          "agent_type" => "executor",
          "node" => "gpu-old@lab",
          "resources" => %{
            "cpu_cores" => 1,
            "memory_mb" => 512,
            "disk_mb" => 0,
            "gpu_count" => 1
          },
          "allocations" => %{
            "devices" => [%{"id" => "cuda-0", "driver" => "cuda"}]
          }
        }
      ])

    RedisStoreStub.put_jobs([job])
    RedisStoreStub.put_agents("gpu-wake-job", [agent_snapshot("worker")])
    {:ok, coordinator} = CoordinatorStub.start_link(self())

    assert {:ok, blocked_result} =
             Reconciler.reconcile_node("gpu-old@lab",
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "gpu-wake-job" -> {:ok, coordinator} end,
               scheduler_opts: [nodes: [small_node(), large_node()], jobs: [job]],
               retry_base_ms: 10
             )

    assert blocked_result.blocked == 1
    assert_receive {:job_persisted, "gpu-wake-job", blocked_updates, _}
    assert blocked_updates["recovery_status"] == "blocked_no_placement"
    refute_received {:coordinator_rescheduled, _, _, _}

    assert {:ok, wake_result} =
             Reconciler.wake_blocked_evals(
               redis_store: RedisStoreStub,
               event_bus: EventBusStub,
               bundle_loader: fn _job -> {:ok, bundle} end,
               lookup_coordinator: fn "gpu-wake-job" -> {:ok, coordinator} end,
               start_job_runner: job_starter(self()),
               scheduler_opts: [
                 nodes: [small_node(), gpu_rejoin_node("gpu-new@lab")],
                 jobs: [job]
               ],
               retry_base_ms: 10,
               reason: "gpu node rejoined"
             )

    assert wake_result.recovered == 1
    assert_receive {:job_started, "gpu-wake-job", opts}
    scheduler_plan = opts[:scheduler_plan]
    assert opts[:restart_reason] =~ "node gpu-old@lab is unavailable"
    assert [%{"agent_id" => "worker", "node" => "gpu-new@lab"}] = scheduler_plan["placements"]

    assert {:ok, [eval]} = RedisStoreStub.list_recovery_evals()
    assert eval["status"] == "complete"
    assert eval["attempt"] == 2
    assert eval["wake_reason"] == "gpu node rejoined"
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

  defp job_starter(parent) do
    fn job_id, _bundle, opts ->
      send(parent, {:job_started, job_id, opts})
      :ok
    end
  end

  defp unique_job_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

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

  defp shared_bundle_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "mn-reconciler-shared-cas-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "payloads"))
    File.write!(Path.join(root, "manifest.json"), Jason.encode!(manifest()))

    on_exit(fn -> File.rm_rf(root) end)

    root
  end

  defp manifest do
    %{
      "manifest_version" => "1.0",
      "graph_id" => "reconcile-test",
      "entrypoints" => ["worker"],
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512},
            "config" => %{"safe_to_retry" => true}
          }
        ],
        "edges" => []
      },
      "policies" => %{"recovery_mode" => "cluster_recover"}
    }
  end

  defp gpu_manifest do
    %{
      "manifest_version" => "1.0",
      "graph_id" => "gpu-reconcile-test",
      "entrypoints" => ["worker"],
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "worker",
            "agent_type" => "executor",
            "role" => "root",
            "resources" => %{
              "cpu_cores" => 1,
              "memory_mb" => 512,
              "devices" => [%{"kind" => "gpu", "driver" => "cuda", "count" => 1}]
            },
            "config" => %{"safe_to_retry" => true}
          }
        ],
        "edges" => []
      },
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

  defp gpu_rejoin_node(name) do
    %{
      "name" => name,
      "status" => "healthy",
      "capabilities" => ["cuda", "llm"],
      "runtime_drivers" => ["host_local"],
      "hardware" => %{
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
          }
        ]
      }
    }
  end

  defp future_iso(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(delay_ms, :millisecond)
    |> DateTime.to_iso8601()
  end
end
