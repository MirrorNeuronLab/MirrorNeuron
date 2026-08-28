defmodule MirrorNeuron.Runtime.JobCleanupTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.HostLocal
  alias MirrorNeuron.Runtime.{JobCleanup, RunnerResources}
  alias MirrorNeuron.Sandbox.{DockerJobSandbox, OpenShellJobSandbox}

  defmodule NodeAdapterStub do
    import Kernel, except: [self: 0]

    def reset(test_pid, failures \\ %{}) do
      :persistent_term.put({__MODULE__, :test_pid}, test_pid)
      :persistent_term.put({__MODULE__, :failures}, failures)
    end

    def self, do: :control@lab
    def list, do: [:connected@lab]
    def connect(_node), do: false
    def disconnect(_node), do: true
    def set_cookie(_node, _cookie), do: :ok

    def rpc_call(node, module, function, args, timeout) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:cleanup_rpc, node, module, function, args, timeout}
      )

      Map.get(:persistent_term.get({__MODULE__, :failures}, %{}), {node, module}, :ok)
    end
  end

  setup do
    previous = Application.get_env(:mirror_neuron, :cluster_node_adapter)
    Application.put_env(:mirror_neuron, :cluster_node_adapter, NodeAdapterStub)

    on_exit(fn ->
      if previous do
        Application.put_env(:mirror_neuron, :cluster_node_adapter, previous)
      else
        Application.delete_env(:mirror_neuron, :cluster_node_adapter)
      end
    end)

    :ok
  end

  test "runtime cleanup sweeps every resource on connected, placed, and assigned nodes" do
    NodeAdapterStub.reset(self())

    job = %{
      "scheduler" => %{
        "placements" => [
          %{"node" => "placed@lab"},
          %{"node" => "connected@lab"}
        ]
      }
    }

    agents = [%{"assigned_node" => "assigned@lab"}]

    assert :ok = JobCleanup.cleanup_runtime_resources("run-1", job, agents)

    nodes = [:control@lab, :connected@lab, :placed@lab, :assigned@lab]

    for node <- nodes,
        {module, function} <- [
          {HostLocal, :terminate_job},
          {OpenShellJobSandbox, :cleanup_job_local},
          {DockerJobSandbox, :cleanup_job_local},
          {RunnerResources, :cleanup_native_resources}
        ] do
      assert_receive {:cleanup_rpc, ^node, ^module, ^function, ["run-1"], 15_000}
    end

    refute_receive {:cleanup_rpc, _node, _module, _function, _args, _timeout}
  end

  test "runtime cleanup attempts every resource and reports all failures" do
    failures = %{
      {:control@lab, HostLocal} => {:error, :host_timeout}
    }

    NodeAdapterStub.reset(self(), failures)

    assert {:error, cleanup_failures} =
             JobCleanup.cleanup_runtime_resources("run-2", nil, [])

    assert Enum.map(cleanup_failures, & &1.resource) == ["HostLocal"]

    assert_receive {:cleanup_rpc, :control@lab, OpenShellJobSandbox, :cleanup_job_local,
                    ["run-2"], 15_000}

    assert_receive {:cleanup_rpc, :control@lab, DockerJobSandbox, :cleanup_job_local, ["run-2"],
                    15_000}
  end

  test "runtime cleanup retires native resources through every owning node" do
    NodeAdapterStub.reset(self())

    job = %{
      "manifest" => %{
        "metadata" => %{"mn_docker_workers" => %{"submission_id" => "submission-1"}}
      }
    }

    assert :ok = JobCleanup.cleanup_runtime_resources("docker-worker-run", job, [])

    for node <- [:control@lab, :connected@lab] do
      assert_receive {:cleanup_rpc, ^node, RunnerResources, :cleanup_native_resources,
                      ["docker-worker-run"], 15_000}
    end
  end

  test "sandbox cleanup also terminates owned HostLocal commands" do
    NodeAdapterStub.reset(self())

    assert :ok = JobCleanup.cleanup_sandboxes("paused-service", nil, [])

    for node <- [:control@lab, :connected@lab],
        {module, function} <- [
          {HostLocal, :terminate_job},
          {OpenShellJobSandbox, :cleanup_job_local},
          {DockerJobSandbox, :cleanup_job_local}
        ] do
      assert_receive {:cleanup_rpc, ^node, ^module, ^function, ["paused-service"], 15_000}
    end

    refute_receive {:cleanup_rpc, _node, _module, _function, _args, _timeout}
  end
end
