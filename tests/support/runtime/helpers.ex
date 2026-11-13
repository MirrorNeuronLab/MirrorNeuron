defmodule MirrorNeuron.RuntimeFixtures.Helpers do
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import MirrorNeuron.RuntimeFixtures.Manifests
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  def put_test_profiles(profiles) do
    previous = Application.get_env(:mirror_neuron, :execution_profiles)
    Application.put_env(:mirror_neuron, :execution_profiles, profiles)

    fn ->
      if previous == nil do
        Application.delete_env(:mirror_neuron, :execution_profiles)
      else
        Application.put_env(:mirror_neuron, :execution_profiles, previous)
      end
    end
  end

  def running_status?(job_id) do
    case MirrorNeuron.inspect_job(job_id) do
      {:ok, %{"status" => "running"}} -> true
      _ -> false
    end
  end

  def cleanup_job_on_exit(job_id) do
    on_exit(fn -> cleanup_runtime_job(job_id) end)
    :ok
  end

  def cleanup_runtime_job(job_id) do
    _ = MirrorNeuron.cancel(job_id)
    RedisStore.delete_job(job_id)
  end

  def assert_runtime_workflow_manifest(job_id) do
    assert {:ok, job} = RedisStore.fetch_job(job_id)
    assert get_in(job, ["manifest", "apiVersion"]) == "mn.workflow/v1"
    assert get_in(job, ["manifest", "kind"]) == "Workflow"
    assert get_in(job, ["manifest", "contract", "outputs"]) == [%{"id" => "review_packet"}]
    assert get_in(job, ["manifest", "flow", "graph", "schema"]) == "mn.workflow.problem_graph/v1"
    assert get_in(job, ["manifest", "flow", "graph", "dynamic", "enabled"]) == false

    assert get_in(job, ["manifest", "flow", "graph", "edges"]) |> Enum.map(& &1["id"]) == [
             "edge-intake-review",
             "edge-review-write"
           ]

    assert get_in(job, ["manifest", "flow", "steps"])
           |> Enum.find(&(&1["id"] == "write_packet"))
           |> get_in(["join", "mode"]) == "all_required"

    assert get_in(job, ["manifest", "runtime", "bindings", "manual_review", "workers"])
           |> Enum.map(& &1["id"]) == ["router_worker", "sink_worker"]
  end

  def worker_pid(job_id) do
    match?(
      [{_pid, _}],
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"})
    )
  end

  def replacement_worker_pid?(job_id, previous_pid) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, "worker"}) do
      [{pid, _}] when pid != previous_pid -> Process.alive?(pid)
      _ -> false
    end
  end

  def attempt_started?(job_id, attempt) do
    case MirrorNeuron.events(job_id) do
      {:ok, events} ->
        Enum.any?(events, fn event ->
          event["type"] == "job_attempt_started" and event["attempt"] == attempt
        end)

      _ ->
        false
    end
  end

  def job_coordinator_registered?(job_id) do
    match?(
      [{_pid, _}],
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id})
    )
  end

  def agent_registered?(job_id, agent_id) do
    match?(
      [{_pid, _}],
      Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id})
    )
  end

  def job_coordinator_pid(job_id) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
      [{pid, _meta}] -> pid
      _ -> flunk("job coordinator was not registered for #{job_id}")
    end
  end

  def trigger_missing_agent_health_check(job_id, agent_id, dead_pid) do
    wait_until(
      fn ->
        not Process.alive?(dead_pid) and agent_unregistered?(job_id, agent_id)
      end,
      2_000
    )

    coordinator = job_coordinator_pid(job_id)
    timer_ref = :sys.get_state(coordinator).health_check_timer_ref
    assert is_reference(timer_ref)
    assert is_integer(Process.read_timer(timer_ref))
    send(coordinator, :health_check)
  end

  def job_runner_pid(job_id, fail? \\ true) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id}) do
      [{pid, _meta}] ->
        pid

      _ when fail? ->
        flunk("job runner was not registered for #{job_id}")

      _ ->
        nil
    end
  end

  def agent_paused?(job_id, agent_id) do
    case agent_snapshot(job_id, agent_id) do
      %{"metadata" => %{"paused" => true}} -> true
      _ -> false
    end
  end

  def agent_pending_count(job_id, agent_id) do
    case agent_snapshot(job_id, agent_id) do
      %{"metadata" => %{"pending_message_count" => count}} when is_integer(count) -> count
      _ -> 0
    end
  end

  def agent_snapshot(job_id, agent_id) do
    case MirrorNeuron.inspect_agents(job_id) do
      {:ok, agents} -> Enum.find(agents, &(&1["agent_id"] == agent_id))
      _ -> nil
    end
  end

  def persist_delivery_job(job_id) do
    assert {:ok, _} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "delivery_version" => 2,
               "lease_epoch" => 1
             })
  end

  def persist_recoverable_job(manifest, suffix, extra_attrs \\ %{}) do
    with {:ok, bundle} <- MirrorNeuron.JobBundle.load(flow_manifest(manifest)) do
      job_id = "#{Runtime.generate_job_id(bundle.manifest.graph_id)}-#{suffix}"
      manifest_map = MirrorNeuron.Manifest.to_map(bundle.manifest)

      {:ok, _job} =
        RedisStore.persist_job(
          job_id,
          Map.merge(
            %{
              "job_id" => job_id,
              "graph_id" => bundle.manifest.graph_id,
              "job_name" => bundle.manifest.job_name,
              "type" => bundle.manifest.type,
              "required_context_engine" => bundle.manifest.required_context_engine,
              "status" => "running",
              "submitted_at" => Runtime.timestamp(),
              "updated_at" => Runtime.timestamp(),
              "root_agent_ids" => bundle.manifest.entrypoints,
              "placement_policy" =>
                Map.get(bundle.manifest.policies, "placement_policy", "local"),
              "recovery_policy" =>
                Map.get(bundle.manifest.policies, "recovery_mode", "local_restart"),
              "result" => nil,
              "topology" => MirrorNeuron.Manifest.topology(bundle.manifest),
              "manifest" => manifest_map,
              "manifest_ref" => %{}
            },
            extra_attrs
          )
        )

      {:ok, job_id}
    end
  end

  def run_manifest(input, opts \\ []) do
    MirrorNeuron.run_manifest(flow_manifest(input), opts)
  end

  def bundle_echo_output(job) do
    candidates = [
      get_in(job, ["result", "output"]),
      get_in(job, ["result", "output", "output"]),
      get_in(job, ["result", "output", "complete_run"]),
      get_in(job, ["result", "complete_run"]),
      decode_bundle_echo_stdout(get_in(job, ["result", "output", "sandbox", "stdout"])),
      decode_bundle_echo_stdout(get_in(job, ["result", "sandbox", "stdout"]))
    ]

    case Enum.find(candidates, &(is_map(&1) and is_binary(Map.get(&1, "bundle_root")))) do
      nil -> flunk("bundle echo output missing from job result: #{inspect(job["result"])}")
      output -> output
    end
  end

  def decode_bundle_echo_stdout(stdout) when is_binary(stdout) do
    case Jason.decode(stdout) do
      {:ok, %{"complete_run" => output}} when is_map(output) -> output
      {:ok, output} when is_map(output) -> output
      _ -> nil
    end
  end

  def decode_bundle_echo_stdout(_stdout), do: nil

  def restore_system_env(key, nil), do: System.delete_env(key)
  def restore_system_env(key, value), do: System.put_env(key, value)

  def deploy_manifest(input, opts) do
    MirrorNeuron.deploy_manifest(flow_manifest(input), opts)
  end

  def update_deployment(deployment_key, input, opts \\ []) do
    MirrorNeuron.update_deployment(deployment_key, flow_manifest(input), opts)
  end

  def redis_key(parts) do
    namespace = MirrorNeuron.Config.string("MN_REDIS_NAMESPACE", :redis_namespace)
    Enum.join([namespace | parts], ":")
  end

  def cleanup_namespace(namespace) do
    case Redix.command(MirrorNeuron.Redis.Connection, ["KEYS", "#{namespace}:*"]) do
      {:ok, []} -> :ok
      {:ok, keys} -> Redix.command(MirrorNeuron.Redis.Connection, ["DEL" | keys])
      _ -> :ok
    end
  end

  def cleanup_runtime_namespace do
    case RedisStore.list_jobs() do
      {:ok, jobs} ->
        Enum.each(jobs, fn job ->
          if job_id = job["job_id"], do: cleanup_runtime_job(job_id)
        end)

      _ ->
        :ok
    end
  end

  def restore_application_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  def restore_application_env(key, value), do: Application.put_env(:mirror_neuron, key, value)

  def agent_unregistered?(job_id, agent_id) do
    Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) == []
  end

  def job_runner_unregistered?(job_id) do
    Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id}) == []
  end

  def checkpoint_proxy(parent, job_id) do
    receive do
      {:agent_checkpoint, agent_id, snapshot} ->
        _ = {job_id, agent_id}
        send(parent, {:checkpoint_ignored, snapshot})
        checkpoint_proxy(parent, job_id)

      _message ->
        checkpoint_proxy(parent, job_id)
    end
  end

  def send_counter_messages(job_id, range) do
    Enum.each(range, fn id ->
      result =
        MirrorNeuron.send_message(job_id, "counter", %{
          "type" => "counter_step",
          "payload" => %{"id" => id}
        })

      assert result == {:ok, "delivered"},
             "counter input #{id} failed with #{inspect(result)}; job=#{inspect(MirrorNeuron.inspect_job(job_id))}"
    end)
  end

  def event_count(job_id, event_type) do
    case MirrorNeuron.events(job_id) do
      {:ok, events} -> Enum.count(events, &(&1["type"] == event_type))
      _ -> 0
    end
  end

  def assert_event_before(events, earlier_type, later_type) do
    earlier_index = event_index(events, earlier_type)
    later_index = event_index(events, later_type)

    assert earlier_index,
           "expected #{earlier_type} event in #{inspect(Enum.map(events, & &1["type"]))}"

    assert later_index,
           "expected #{later_type} event in #{inspect(Enum.map(events, & &1["type"]))}"

    assert earlier_index < later_index,
           "expected #{earlier_type} before #{later_type}, got #{inspect(Enum.map(events, & &1["type"]))}"
  end

  def event_index(events, event_type) do
    Enum.find_index(events, &(&1["type"] == event_type))
  end

  def wait_until(fun, timeout \\ 1_000) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_until(fun, started_at, timeout)
  end

  def do_wait_until(fun, started_at, timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) - started_at > timeout do
        flunk("condition was not met within #{timeout}ms")
      else
        Process.sleep(20)
        do_wait_until(fun, started_at, timeout)
      end
    end
  end
end
