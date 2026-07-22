defmodule MirrorNeuron.Runtime.JobRunnerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.JobRunner

  setup do
    old_duration_env = System.get_env("MN_JOB_LEASE_DURATION_MS")
    old_renew_env = System.get_env("MN_JOB_LEASE_RENEW_INTERVAL_MS")
    old_duration_config = Application.get_env(:mirror_neuron, :job_lease_duration_ms)
    old_renew_config = Application.get_env(:mirror_neuron, :job_lease_renew_interval_ms)

    on_exit(fn ->
      restore_system_env("MN_JOB_LEASE_DURATION_MS", old_duration_env)
      restore_system_env("MN_JOB_LEASE_RENEW_INTERVAL_MS", old_renew_env)
      restore_app_env(:job_lease_duration_ms, old_duration_config)
      restore_app_env(:job_lease_renew_interval_ms, old_renew_config)
    end)

    :ok
  end

  test "child spec carries preferred start node for Horde placement" do
    spec =
      JobRunner.child_spec(
        {"job-1", :manifest, [preferred_start_node: "mirror_neuron@127.0.0.1"]}
      )

    assert spec.mirror_neuron_target_node == "mirror_neuron@127.0.0.1"
  end

  test "child spec omits target node when no preferred start node is set" do
    spec = JobRunner.child_spec({"job-1", :manifest, []})

    refute Map.has_key?(spec, :mirror_neuron_target_node)
  end

  test "job lease timing defaults to 60s duration and 10s renewal" do
    System.delete_env("MN_JOB_LEASE_DURATION_MS")
    System.delete_env("MN_JOB_LEASE_RENEW_INTERVAL_MS")
    Application.delete_env(:mirror_neuron, :job_lease_duration_ms)
    Application.delete_env(:mirror_neuron, :job_lease_renew_interval_ms)

    assert JobRunner.lease_duration_ms() == 60_000
    assert JobRunner.lease_renew_interval_ms() == 10_000
  end

  test "job lease timing honors environment overrides" do
    System.put_env("MN_JOB_LEASE_DURATION_MS", "90000")
    System.put_env("MN_JOB_LEASE_RENEW_INTERVAL_MS", "15000")

    assert JobRunner.lease_duration_ms() == 90_000
    assert JobRunner.lease_renew_interval_ms() == 15_000
  end

  test "invalid job lease timing env values fall back to app config or defaults" do
    Application.put_env(:mirror_neuron, :job_lease_duration_ms, 45_000)
    Application.put_env(:mirror_neuron, :job_lease_renew_interval_ms, 7_000)
    System.put_env("MN_JOB_LEASE_DURATION_MS", "not-an-int")
    System.put_env("MN_JOB_LEASE_RENEW_INTERVAL_MS", "0")

    assert JobRunner.lease_duration_ms() == 45_000
    assert JobRunner.lease_renew_interval_ms() == 7_000

    Application.put_env(:mirror_neuron, :job_lease_duration_ms, -1)
    Application.put_env(:mirror_neuron, :job_lease_renew_interval_ms, "bad")

    assert JobRunner.lease_duration_ms() == 60_000
    assert JobRunner.lease_renew_interval_ms() == 10_000
  end

  test "runner termination stops its coordinator even for a normal shutdown" do
    coordinator = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(coordinator)
    lease_timer_token = make_ref()

    lease_timer_ref =
      Process.send_after(self(), {:renew_lease, lease_timer_token}, 60_000)

    assert :ok =
             JobRunner.terminate(:normal, %{
               job_id: "terminate-#{System.unique_integer([:positive])}",
               coordinator: coordinator,
               node_name: to_string(Node.self()),
               lease: %{"epoch" => 1},
               lease_timer_ref: lease_timer_ref,
               lease_timer_token: lease_timer_token
             })

    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :shutdown}
    assert Process.read_timer(lease_timer_ref) == false
  end

  test "failed coordinator startup releases the acquired job lease" do
    job_id = "runner-start-failure-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Horde.Registry.unregister(MirrorNeuron.DistributedRegistry, {:job, job_id})
      RedisStore.delete_job(job_id)
    end)

    assert {:ok, _registration} =
             Horde.Registry.register(MirrorNeuron.DistributedRegistry, {:job, job_id}, nil)

    assert {:ok, bundle} =
             JobBundle.load(%{
               "manifest_version" => "1.0",
               "graph_id" => "runner_start_failure",
               "entrypoints" => ["root"],
               "flow" => %{
                 "nodes" => [%{"node_id" => "root", "agent_type" => "router"}],
                 "edges" => []
               }
             })

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "pending",
               "attempt" => 0,
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:stop, {:already_started, _pid}} = JobRunner.init({job_id, bundle.manifest, []})
    assert {:ok, nil} = RedisStore.get_lease("job:#{job_id}")

    assert {:ok, %{"lease" => nil, "lease_epoch" => nil, "lease_owner" => nil}} =
             RedisStore.fetch_job(job_id)
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
