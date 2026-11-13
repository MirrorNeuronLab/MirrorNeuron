defmodule MirrorNeuron.Runtime.FlowsTest.Handler do
  use MirrorNeuron.AgentTemplate
  def init(_node), do: {:ok, %{handled: 0}}

  def handle_message(message, state, context) do
    id = MirrorNeuron.Message.id(message)
    send(context.coordinator, {:handler_started, id, self()})

    if id == "blocking",
      do:
        (receive do
           :release_handler -> :ok
         end)

    {:ok, %{handled: state.handled + 1}, []}
  end
end

defmodule MirrorNeuron.RuntimeFlowCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.RuntimeFlowCase
    end
  end

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore

  defmodule RetryRunner do
    def run(_payload, config, opts) do
      attempt = Keyword.fetch!(opts, :attempt)
      send(config["observer"], {:runner_attempt, attempt})

      if attempt == 1 and config["fail_first"] do
        {:error, %{"error" => "runner unavailable"}}
      else
        {:ok, %{"exit_code" => 0, "stdout" => "{}", "stderr" => "", "logs" => ""}}
      end
    end
  end

  setup_all do
    env_keys = [
      "MN_REDIS_URL",
      "MN_REDIS_HA_MODE",
      "MN_REDIS_NAMESPACE",
      "MN_REDIS_WAIT_REPLICAS",
      "MN_REDIS_RECONNECT_ATTEMPTS"
    ]

    previous_env = Map.new(env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    url = System.fetch_env!("MN_FLOW_REDIS_URL")
    System.put_env("MN_REDIS_URL", url)
    System.put_env("MN_REDIS_HA_MODE", "standalone")
    System.put_env("MN_REDIS_NAMESPACE", "flow-test-#{System.unique_integer([:positive])}")
    System.put_env("MN_REDIS_WAIT_REPLICAS", "0")
    System.put_env("MN_REDIS_RECONNECT_ATTEMPTS", "0")
    Application.ensure_all_started(:redix)
    Application.ensure_all_started(:horde)

    start_supervised!(
      {Horde.Registry, name: MirrorNeuron.DistributedRegistry, keys: :unique, members: :auto}
    )

    start_supervised!({Registry, keys: :duplicate, name: MirrorNeuron.Runtime.EventRegistry})
    start_supervised!({Registry, keys: :unique, name: MirrorNeuron.Runtime.ErrorMonitor.Registry})
    start_supervised!(MirrorNeuron.Runtime.ErrorMonitor)

    start_supervised!(
      {Task.Supervisor, name: MirrorNeuron.Runtime.SignalTaskSupervisor, max_children: 256}
    )

    unless Process.whereis(MirrorNeuron.Runtime.JobResponseRegistry),
      do:
        start_supervised!(
          {Registry, keys: :unique, name: MirrorNeuron.Runtime.JobResponseRegistry}
        )

    unless Process.whereis(MirrorNeuron.Runtime.JobResponseSupervisor),
      do:
        start_supervised!(
          {DynamicSupervisor,
           strategy: :one_for_one, name: MirrorNeuron.Runtime.JobResponseSupervisor}
        )

    start_supervised!({Redix, {url, [name: MirrorNeuron.Redis.Connection]}})
    start_supervised!(MirrorNeuron.Persistence.ProtectedRedis)
    start_supervised!({Registry, keys: :duplicate, name: MirrorNeuron.Runtime.SignalRegistry})
    :ok
  end

  setup do
    run = "run-#{System.unique_integer([:positive])}"

    job = %{
      "job_id" => run,
      "delivery_version" => 2,
      "status" => "running",
      "manifest" => %{
        "nodes" => [%{"node_id" => "worker", "config" => %{"max_queue_depth" => 8}}]
      }
    }

    # Seed the same guard and projection records used by production admission.
    {:ok, _job} = RedisStore.persist_job(run, job)

    %{run: run}
  end

  def message(run, id, opts \\ []),
    do:
      Message.new(
        run,
        "source",
        "worker",
        "work",
        %{"value" => id},
        Keyword.put(opts, :message_id, id)
      )

  def executor(run, config) do
    manager =
      start_supervised!(
        {MirrorNeuron.Execution.LeaseManager,
         name: __MODULE__.Leases, capacities: %{"default" => 1}}
      )

    node = %{
      node_id: "worker",
      config:
        Map.merge(
          config,
          %{"runner_module" => RetryRunner, "lease_manager" => manager, "observer" => self()}
        )
    }

    {:ok, state} = MirrorNeuron.Builtins.Executor.init(node)

    context = %{
      job_id: run,
      node: node,
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp"
    }

    {state, context}
  end
end
