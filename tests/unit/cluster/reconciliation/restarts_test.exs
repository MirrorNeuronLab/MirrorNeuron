defmodule MirrorNeuron.Cluster.ReconcilerTest.RestartsTest do
  use MirrorNeuron.ReconciliationCase, async: false

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.ReconciliationCase.RedisStoreStub
  alias MirrorNeuron.ReconciliationCase.EventBusStub
  alias MirrorNeuron.ReconciliationCase.CoordinatorStub

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
end
