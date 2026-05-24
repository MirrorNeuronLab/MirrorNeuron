defmodule MirrorNeuron.Cluster.NodeDrainerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Cluster.NodeDrainer

  @test_pid_name :node_drainer_test_pid

  defmodule NodeStateStub do
    def put(state), do: :persistent_term.put({__MODULE__, :states}, state)

    def fetch(node) do
      case Map.get(:persistent_term.get({__MODULE__, :states}, %{}), to_string(node)) do
        nil -> {:error, :not_found}
        state -> {:ok, state}
      end
    end

    def list, do: :persistent_term.get({__MODULE__, :states}, %{}) |> Map.values()

    def mark(node, status, attrs) do
      node = to_string(node)
      state = attrs |> Map.put("node", node) |> Map.put("status", status)
      states = :persistent_term.get({__MODULE__, :states}, %{})
      :persistent_term.put({__MODULE__, :states}, Map.put(states, node, state))
      send(Process.whereis(:node_drainer_test_pid), {:node_marked, node, status, state})
      {:ok, state}
    end
  end

  defmodule RedisStoreStub do
    def put_jobs(jobs), do: :persistent_term.put({__MODULE__, :jobs}, jobs)
    def list_jobs, do: {:ok, :persistent_term.get({__MODULE__, :jobs}, [])}
    def list_node_states, do: {:ok, []}
  end

  defmodule ReconcilerStub do
    def put_result(result), do: :persistent_term.put({__MODULE__, :result}, result)

    def reconcile_node(node, opts) do
      send(Process.whereis(:node_drainer_test_pid), {:reconciled, node, opts})
      {:ok, :persistent_term.get({__MODULE__, :result}, %{recovered: 1, jobs: []})}
    end
  end

  defmodule EventBusStub do
    def publish(job_id, event) do
      send(Process.whereis(:node_drainer_test_pid), {:event_published, job_id, event})
      :ok
    end
  end

  setup do
    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)
    NodeStateStub.put(%{})
    RedisStoreStub.put_jobs([])
    ReconcilerStub.put_result(%{recovered: 1, jobs: []})

    on_exit(fn ->
      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      :persistent_term.erase({NodeStateStub, :states})
      :persistent_term.erase({RedisStoreStub, :jobs})
      :persistent_term.erase({ReconcilerStub, :result})
    end)

    :ok
  end

  test "dry-run reports planned service migration without mutating node state" do
    RedisStoreStub.put_jobs([service_job("svc")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               dry_run: true,
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "dry_run"
    assert result["would_status"] == "complete"
    assert [%{"status" => "would_migrate"}] = result["actions"]
    refute_receive {:node_marked, _, _, _}
    assert_receive {:reconciled, "small@lab", opts}
    assert opts[:trigger] == "node_drain"
    assert opts[:skip_reschedule_policy]
    assert opts[:skip_reschedule_policy_record]
    assert opts[:only_job_ids] == ["svc"]
  end

  test "successful service drain completes into maintenance without consuming reschedule policy" do
    RedisStoreStub.put_jobs([service_job("svc")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               reason: "kernel update",
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "complete"
    assert result["node_status"] == "maintenance"
    assert result["scheduling_eligible"] == false
    assert_receive {:node_marked, "small@lab", "draining", draining_state}
    assert get_in(draining_state, ["drain", "status"]) == "draining"
    assert_receive {:reconciled, "small@lab", opts}
    assert opts[:skip_reschedule_policy_record]
    assert_receive {:node_marked, "small@lab", "maintenance", maintenance_state}
    assert get_in(maintenance_state, ["drain", "status"]) == "complete"
    assert_receive {:event_published, "__cluster__", %{type: :node_drain_started}}
    assert_receive {:event_published, "__cluster__", %{type: :node_drain_completed}}
  end

  test "batch jobs wait before the deadline and block drain completion" do
    RedisStoreStub.put_jobs([batch_job("batch")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               deadline_ms: 60_000,
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "draining"
    assert [%{"status" => "waiting"}] = result["actions"]
    assert_receive {:node_marked, "small@lab", "draining", _}
    assert_receive {:node_marked, "small@lab", "draining", state}
    assert get_in(state, ["drain", "status"]) == "draining"
    refute_receive {:reconciled, _, _}
  end

  test "batch jobs migrate after the drain deadline expires" do
    RedisStoreStub.put_jobs([batch_job("batch")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               deadline_ms: 0,
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "complete"
    assert [%{"job_id" => "batch", "status" => "migrated"}] = result["actions"]
    assert_receive {:reconciled, "small@lab", opts}
    assert opts[:trigger] == "node_drain"
    assert opts[:only_job_ids] == ["batch"]
  end

  test "completed batch jobs no longer block drain completion" do
    RedisStoreStub.put_jobs([batch_job("done") |> Map.put("status", "completed")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "complete"
    assert result["actions"] == []
    assert result["counters"] == %{"checked" => 0}
    refute_receive {:reconciled, _, _}
  end

  test "system jobs are ignored by default and do not block completion" do
    RedisStoreStub.put_jobs([system_job("sys")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "complete"
    assert [%{"status" => "ignored"}] = result["actions"]
    refute_receive {:reconciled, _, _}
  end

  test "system jobs can be included when the operator asks for them" do
    RedisStoreStub.put_jobs([system_job("sys")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               ignore_system_jobs: false,
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "complete"
    assert [%{"job_id" => "sys", "status" => "migrated"}] = result["actions"]
    assert_receive {:reconciled, "small@lab", opts}
    assert opts[:only_job_ids] == ["sys"]
  end

  test "coordinator lease on the draining node is enough to trigger a migration" do
    job =
      service_job("lease-owner")
      |> Map.put("lease_owner", "small@lab")
      |> put_in(["scheduler", "placements"], [
        %{
          "agent_id" => "worker",
          "node" => "large@lab",
          "resources" => %{"cpu_cores" => 1, "memory_mb" => 512}
        }
      ])

    RedisStoreStub.put_jobs([job])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "complete"
    assert [%{"job_id" => "lease-owner", "affected_agents" => []}] = result["actions"]
    assert_receive {:reconciled, "small@lab", opts}
    assert opts[:only_job_ids] == ["lease-owner"]
  end

  test "blocked placement leaves node draining for later leader retries" do
    ReconcilerStub.put_result(%{blocked: 1, jobs: []})
    RedisStoreStub.put_jobs([service_job("svc")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "blocked_no_placement"
    assert_receive {:node_marked, "small@lab", "draining", _}
    assert_receive {:reconciled, "small@lab", _}
    assert_receive {:node_marked, "small@lab", "draining", state}
    assert get_in(state, ["drain", "status"]) == "blocked_no_placement"
    assert_receive {:event_published, "__cluster__", %{type: :node_drain_blocked}}
  end

  test "paused drain leftovers stay in review instead of completing the drain" do
    ReconcilerStub.put_result(%{paused: 1, jobs: []})
    RedisStoreStub.put_jobs([service_job("unsafe")])

    assert {:ok, result} =
             NodeDrainer.drain_node("small@lab",
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["status"] == "paused_for_review"
    assert [%{"status" => "paused_for_review"}] = result["actions"]
    assert_receive {:node_marked, "small@lab", "draining", _}
    assert_receive {:node_marked, "small@lab", "draining", state}
    assert get_in(state, ["drain", "status"]) == "paused_for_review"
    assert_receive {:event_published, "__cluster__", %{type: :node_drain_progress}}
  end

  test "due drain sweep retries draining and blocked nodes" do
    NodeStateStub.put(%{
      "small@lab" => %{
        "node" => "small@lab",
        "status" => "draining",
        "scheduling_eligible" => false,
        "drain" => %{
          "status" => "blocked_no_placement",
          "started_at" => "2026-05-24T10:00:00Z",
          "deadline_at" => "2026-05-24T10:30:00Z",
          "reason" => "retry drain",
          "ignore_system_jobs" => true
        }
      },
      "large@lab" => %{
        "node" => "large@lab",
        "status" => "maintenance",
        "scheduling_eligible" => false,
        "drain" => %{"status" => "complete"}
      }
    })

    RedisStoreStub.put_jobs([service_job("svc")])

    assert {:ok, result} =
             NodeDrainer.process_due_drains(
               redis_store: RedisStoreStub,
               node_state: NodeStateStub,
               reconciler: ReconcilerStub,
               event_bus: EventBusStub
             )

    assert result["checked"] == 1
    assert result["completed"] == 1
    assert [%{"node" => "small@lab", "status" => "complete"}] = result["nodes"]
    assert_receive {:reconciled, "small@lab", opts}
    assert opts[:continue] == true
    assert opts[:reason] == "retry drain"
  end

  test "cancel drain and maintenance toggles update scheduling eligibility exactly" do
    NodeStateStub.put(%{
      "small@lab" => %{
        "node" => "small@lab",
        "status" => "draining",
        "scheduling_eligible" => false,
        "drain" => %{"status" => "draining"}
      }
    })

    assert {:ok, cancelled} =
             NodeDrainer.cancel_node_drain("small@lab",
               mark_eligible: true,
               node_state: NodeStateStub,
               event_bus: EventBusStub
             )

    assert cancelled["scheduling_eligible"] == true
    assert_receive {:node_marked, "small@lab", "healthy", state}
    assert get_in(state, ["drain", "status"]) == "cancelled"

    assert {:ok, maintenance} =
             NodeDrainer.set_node_maintenance("small@lab", true,
               reason: "replace disk",
               node_state: NodeStateStub,
               event_bus: EventBusStub
             )

    assert maintenance["status"] == "maintenance"
    assert maintenance["scheduling_eligible"] == false
    assert_receive {:node_marked, "small@lab", "maintenance", state}
    assert state["scheduling_eligible"] == false

    assert {:ok, enabled} =
             NodeDrainer.set_node_maintenance("small@lab", false,
               node_state: NodeStateStub,
               event_bus: EventBusStub
             )

    assert enabled["status"] == "healthy"
    assert enabled["scheduling_eligible"] == true
    assert_receive {:node_marked, "small@lab", "healthy", state}
    assert state["scheduling_eligible"] == true
  end

  defp service_job(job_id) do
    base_job(job_id)
    |> Map.put("job_type", "service")
    |> put_in(["scheduler", "job_type"], "service")
  end

  defp batch_job(job_id) do
    base_job(job_id)
    |> Map.put("job_type", "batch")
    |> put_in(["scheduler", "job_type"], "batch")
  end

  defp system_job(job_id) do
    base_job(job_id)
    |> Map.put("job_type", "system")
    |> put_in(["scheduler", "job_type"], "system")
  end

  defp base_job(job_id) do
    %{
      "job_id" => job_id,
      "status" => "running",
      "recovery_policy" => "cluster_recover",
      "scheduler" => %{
        "placements" => [
          %{
            "agent_id" => "worker",
            "node" => "small@lab",
            "resources" => %{"cpu_cores" => 1, "memory_mb" => 512}
          }
        ]
      }
    }
  end
end
