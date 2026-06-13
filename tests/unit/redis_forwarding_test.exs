defmodule MirrorNeuron.Persistence.RedisForwardingTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Persistence.RedisStore

  @namespace "mirror_neuron_redis_forwarding_test"
  @test_pid_name :redis_forwarding_test_pid

  defmodule ClusterNodeAdapterStub do
    @test_pid_name :redis_forwarding_test_pid

    def reset do
      :persistent_term.put({__MODULE__, :list}, [])
      :persistent_term.put({__MODULE__, :rpc_results}, %{})
    end

    def self, do: :control@lab
    def list, do: :persistent_term.get({__MODULE__, :list}, [])
    def put_list(nodes), do: :persistent_term.put({__MODULE__, :list}, nodes)
    def connect(_node), do: true
    def disconnect(_node), do: true
    def set_cookie(_node, _cookie), do: :ok

    def put_rpc_result(node, module, function, args, result) do
      key = {node, module, function, args}
      results = :persistent_term.get({__MODULE__, :rpc_results}, %{})
      :persistent_term.put({__MODULE__, :rpc_results}, Map.put(results, key, result))
    end

    def rpc_call(node, module, function, args, timeout) do
      send(Process.whereis(@test_pid_name), {:rpc_call, node, module, function, args, timeout})

      :persistent_term.get({__MODULE__, :rpc_results}, %{})
      |> Map.get({node, module, function, args}, {:badrpc, :unexpected_call})
    end
  end

  setup do
    if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
    Process.register(self(), @test_pid_name)

    old_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    old_reconnect_attempts = Application.get_env(:mirror_neuron, :redis_reconnect_attempts)
    old_system_namespace = System.get_env("MN_REDIS_NAMESPACE")
    old_forward_primary = System.get_env("MN_REDIS_FORWARD_PRIMARY")
    old_wait_replicas = System.get_env("MN_REDIS_WAIT_REPLICAS")
    old_reconnect_attempts_env = System.get_env("MN_REDIS_RECONNECT_ATTEMPTS")

    ClusterNodeAdapterStub.reset()
    Application.put_env(:mirror_neuron, :cluster_node_adapter, ClusterNodeAdapterStub)
    Application.put_env(:mirror_neuron, :redis_namespace, @namespace)
    Application.put_env(:mirror_neuron, :redis_reconnect_attempts, 0)
    System.put_env("MN_REDIS_NAMESPACE", @namespace)
    System.put_env("MN_REDIS_FORWARD_PRIMARY", "true")
    System.put_env("MN_REDIS_WAIT_REPLICAS", "0")
    System.put_env("MN_REDIS_RECONNECT_ATTEMPTS", "0")

    on_exit(fn ->
      ClusterNodeAdapterStub.reset()
      if Process.whereis(@test_pid_name), do: Process.unregister(@test_pid_name)
      restore_env(:cluster_node_adapter, old_adapter)
      restore_env(:redis_namespace, old_namespace)
      restore_env(:redis_reconnect_attempts, old_reconnect_attempts)
      restore_system_env("MN_REDIS_NAMESPACE", old_system_namespace)
      restore_system_env("MN_REDIS_FORWARD_PRIMARY", old_forward_primary)
      restore_system_env("MN_REDIS_WAIT_REPLICAS", old_wait_replicas)
      restore_system_env("MN_REDIS_RECONNECT_ATTEMPTS", old_reconnect_attempts_env)
    end)
  end

  test "forwards Redis commands to the first non-network-only peer" do
    primary = :primary@lab
    worker = :"network-only@lab"
    job_id = "job-forwarded"
    command = ["GET", "#{@namespace}:job:#{job_id}"]

    ClusterNodeAdapterStub.put_list([worker, primary])

    ClusterNodeAdapterStub.put_rpc_result(
      worker,
      MirrorNeuron.Grpc.NetworkOnly,
      :enabled?,
      [],
      true
    )

    ClusterNodeAdapterStub.put_rpc_result(
      primary,
      MirrorNeuron.Grpc.NetworkOnly,
      :enabled?,
      [],
      false
    )

    ClusterNodeAdapterStub.put_rpc_result(
      primary,
      RedisStore,
      :redis_command_from_peer,
      [command],
      {:ok, Jason.encode!(%{"job_id" => job_id, "status" => "running"})}
    )

    assert {:ok, %{"job_id" => ^job_id, "status" => "running"}} = RedisStore.fetch_job(job_id)

    assert_receive {:rpc_call, ^worker, MirrorNeuron.Grpc.NetworkOnly, :enabled?, [], 1_000}
    assert_receive {:rpc_call, ^primary, MirrorNeuron.Grpc.NetworkOnly, :enabled?, [], 1_000}
    assert_receive {:rpc_call, ^primary, RedisStore, :redis_command_from_peer, [^command], 5_000}
  end

  test "forwards Redis transaction pipelines to the primary peer" do
    primary = :primary@lab
    schedule_id = "schedule-forwarded"

    commands = [
      ["MULTI"],
      ["DEL", "#{@namespace}:schedule:#{schedule_id}"],
      ["SREM", "#{@namespace}:schedules", schedule_id],
      ["ZREM", "#{@namespace}:schedule:due", schedule_id],
      ["EXEC"]
    ]

    ClusterNodeAdapterStub.put_list([primary])

    ClusterNodeAdapterStub.put_rpc_result(
      primary,
      MirrorNeuron.Grpc.NetworkOnly,
      :enabled?,
      [],
      false
    )

    ClusterNodeAdapterStub.put_rpc_result(
      primary,
      RedisStore,
      :redis_pipeline_from_peer,
      [commands],
      {:ok, ["OK", "QUEUED", "QUEUED", "QUEUED", [1, 1, 1]]}
    )

    assert :ok = RedisStore.delete_schedule(schedule_id)

    assert_receive {:rpc_call, ^primary, MirrorNeuron.Grpc.NetworkOnly, :enabled?, [], 1_000}

    assert_receive {:rpc_call, ^primary, RedisStore, :redis_pipeline_from_peer, [^commands],
                    5_000}
  end

  test "falls back to the local Redis error path when no primary peer exists" do
    worker = :"network-only@lab"
    ClusterNodeAdapterStub.put_list([worker])

    ClusterNodeAdapterStub.put_rpc_result(
      worker,
      MirrorNeuron.Grpc.NetworkOnly,
      :enabled?,
      [],
      true
    )

    assert {:error, _reason} = RedisStore.fetch_job("missing-job")

    assert_receive {:rpc_call, ^worker, MirrorNeuron.Grpc.NetworkOnly, :enabled?, [], 1_000}
  end

  test "falls back to the local Redis error path when primary forwarding RPC fails" do
    primary = :primary@lab
    job_id = "missing-after-badrpc"
    command = ["GET", "#{@namespace}:job:#{job_id}"]

    ClusterNodeAdapterStub.put_list([primary])

    ClusterNodeAdapterStub.put_rpc_result(
      primary,
      MirrorNeuron.Grpc.NetworkOnly,
      :enabled?,
      [],
      false
    )

    ClusterNodeAdapterStub.put_rpc_result(
      primary,
      RedisStore,
      :redis_command_from_peer,
      [command],
      {:badrpc, :nodedown}
    )

    assert {:error, _reason} = RedisStore.fetch_job(job_id)

    assert_receive {:rpc_call, ^primary, MirrorNeuron.Grpc.NetworkOnly, :enabled?, [], 1_000}
    assert_receive {:rpc_call, ^primary, RedisStore, :redis_command_from_peer, [^command], 5_000}
  end

  defp restore_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
