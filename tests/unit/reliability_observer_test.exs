defmodule MirrorNeuron.Runtime.ReliabilityObserverTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.ReliabilityObserver

  @test_pid_name :reliability_observer_test_pid

  defmodule RedisStoreStub do
    def put_jobs(jobs), do: :persistent_term.put({__MODULE__, :jobs}, jobs)

    def list_jobs, do: {:ok, :persistent_term.get({__MODULE__, :jobs}, [])}
  end

  defmodule EventBusStub do
    def publish(job_id, event) do
      send(Process.whereis(:reliability_observer_test_pid), {:event_published, job_id, event})
      :ok
    end
  end

  setup do
    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)
    RedisStoreStub.put_jobs([])

    on_exit(fn ->
      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      :persistent_term.erase({RedisStoreStub, :jobs})
    end)

    :ok
  end

  test "publishes degraded and restored notices as nodes remove and rejoin" do
    job = cluster_recovery_job("observer-cluster-job")
    RedisStoreStub.put_jobs([job])

    {:ok, observer} =
      ReliabilityObserver.start_link(
        name: unique_name(),
        schedule_initial_tick: false,
        interval_ms: 60_000,
        snapshot: &snapshot/0,
        redis_store: RedisStoreStub,
        event_bus: EventBusStub
      )

    set_snapshot(single_node_snapshot())
    send(observer, :tick)

    assert_receive {:event_published, "__cluster__",
                    %{type: :cluster_reliability_mode_changed, mode: "single_node"}}

    assert_receive {:event_published, "observer-cluster-job",
                    %{type: :job_reliability_degraded, mode: "single_node"}}

    set_snapshot(multi_node_snapshot())
    send(observer, :tick)

    assert_receive {:event_published, "__cluster__",
                    %{type: :cluster_reliability_mode_changed, mode: "multi_node"}}

    assert_receive {:event_published, "observer-cluster-job",
                    %{type: :job_reliability_restored, mode: "multi_node"}}

    set_snapshot(single_node_snapshot())
    send(observer, :tick)

    assert_receive {:event_published, "__cluster__",
                    %{type: :cluster_reliability_mode_changed, mode: "single_node"}}

    assert_receive {:event_published, "observer-cluster-job",
                    %{type: :job_reliability_degraded, mode: "single_node"}}
  end

  test "restored notice does not rewrite persisted job policy" do
    job =
      "observer-degraded-job"
      |> cluster_recovery_job()
      |> Map.put("recovery_policy", "local_restart")
      |> Map.put("requested_recovery_policy", "cluster_recover")
      |> Map.put("reliability", %{
        "degraded" => true,
        "effective_recovery_policy" => "local_restart"
      })

    RedisStoreStub.put_jobs([job])

    {:ok, observer} =
      ReliabilityObserver.start_link(
        name: unique_name(),
        schedule_initial_tick: false,
        interval_ms: 60_000,
        snapshot: &snapshot/0,
        redis_store: RedisStoreStub,
        event_bus: EventBusStub
      )

    set_snapshot(multi_node_snapshot())
    send(observer, :tick)

    assert_receive {:event_published, "observer-degraded-job",
                    %{type: :job_reliability_restored, mode: "multi_node"}}

    assert {:ok, [persisted]} = RedisStoreStub.list_jobs()
    assert persisted["requested_recovery_policy"] == "cluster_recover"
    assert persisted["recovery_policy"] == "local_restart"
    assert get_in(persisted, ["reliability", "degraded"]) == true
  end

  defp cluster_recovery_job(job_id) do
    manifest = manifest_map()

    %{
      "job_id" => job_id,
      "status" => "running",
      "requested_recovery_policy" => "cluster_recover",
      "recovery_policy" => "cluster_recover",
      "manifest" => manifest,
      "manifest_ref" => %{"bundle_storage" => "redis", "bundle_fingerprint" => "sha256-test"},
      "reliability" => %{"degraded" => false, "effective_recovery_policy" => "cluster_recover"}
    }
  end

  defp manifest_map do
    {:ok, manifest} =
      Manifest.load(%{
        "manifest_version" => "1.0",
        "graph_id" => "observer-reliability-test",
        "entrypoints" => ["worker"],
        "nodes" => [
          %{"node_id" => "worker", "agent_type" => "executor", "role" => "root_coordinator"}
        ],
        "edges" => [],
        "policies" => %{"recovery_mode" => "cluster_recover"}
      })

    Manifest.to_map(manifest)
  end

  defp single_node_snapshot do
    self_node = to_string(Node.self())

    %{
      mode: "single_node",
      observed_nodes: [self_node],
      observed_at: "2026-05-17T00:00:00.000Z",
      node_states: [%{"node" => self_node, "status" => "healthy", "node_role" => "runtime"}]
    }
  end

  defp multi_node_snapshot do
    self_node = to_string(Node.self())
    remote = "runtime-b@127.0.0.1"

    %{
      mode: "multi_node",
      observed_nodes: [self_node, remote],
      observed_at: "2026-05-17T00:00:10.000Z",
      node_states: [
        %{"node" => self_node, "status" => "healthy", "node_role" => "runtime"},
        %{"node" => remote, "status" => "healthy", "node_role" => "runtime"}
      ]
    }
  end

  defp set_snapshot(snapshot), do: :persistent_term.put({__MODULE__, :snapshot}, snapshot)
  defp snapshot, do: :persistent_term.get({__MODULE__, :snapshot}, single_node_snapshot())

  defp unique_name do
    :"reliability-observer-test-#{System.unique_integer([:positive])}"
  end
end
