defmodule MirrorNeuron.SandboxCleanupOwnershipTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Sandbox.{DockerJobSandbox, OpenShellJobSandbox}

  setup do
    previous_native = System.get_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP")
    previous_timeout = Application.get_env(:mirror_neuron, :sandbox_owner_cleanup_timeout_ms)

    previous_ensure_timeout =
      Application.get_env(:mirror_neuron, :sandbox_owner_ensure_timeout_ms)

    System.put_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP", "true")
    Application.put_env(:mirror_neuron, :sandbox_owner_cleanup_timeout_ms, 20)
    Application.put_env(:mirror_neuron, :sandbox_owner_ensure_timeout_ms, 20)

    on_exit(fn ->
      restore_system_env("MN_CORE_ALLOW_NATIVE_SANDBOX_PREP", previous_native)
      restore_app_env(:sandbox_owner_cleanup_timeout_ms, previous_timeout)
      restore_app_env(:sandbox_owner_ensure_timeout_ms, previous_ensure_timeout)
    end)

    :ok
  end

  test "unresponsive Docker sandbox owners are stopped after the cleanup deadline" do
    job_id = "stuck-docker-owner-#{System.unique_integer([:positive])}"
    key = {:docker_worker, job_id}
    pid = start_unresponsive_owner(key)

    assert {:error, :sandbox_owner_cleanup_timeout} =
             DockerJobSandbox.cleanup_job_local(job_id)

    refute Process.alive?(pid)
    assert_eventually(fn -> Registry.lookup(MirrorNeuron.Sandbox.Registry, key) == [] end)
  end

  test "unresponsive OpenShell sandbox owners are stopped after the cleanup deadline" do
    job_id = "stuck-openshell-owner-#{System.unique_integer([:positive])}"
    pid = start_unresponsive_owner(job_id)

    assert {:error, :sandbox_owner_cleanup_timeout} =
             OpenShellJobSandbox.cleanup_job_local(job_id)

    refute Process.alive?(pid)
    assert_eventually(fn -> Registry.lookup(MirrorNeuron.Sandbox.Registry, job_id) == [] end)
  end

  test "unresponsive Docker sandbox owners cannot block ensure forever" do
    job_id = "stuck-docker-ensure-#{System.unique_integer([:positive])}"
    key = {:docker_worker, job_id}
    pid = start_unresponsive_owner(key)

    assert {:error, :sandbox_owner_ensure_timeout} =
             DockerJobSandbox.ensure(job_id, "worker:latest", %{})

    refute Process.alive?(pid)
    assert_eventually(fn -> Registry.lookup(MirrorNeuron.Sandbox.Registry, key) == [] end)
  end

  test "unresponsive OpenShell sandbox owners cannot block ensure forever" do
    job_id = "stuck-openshell-ensure-#{System.unique_integer([:positive])}"
    pid = start_unresponsive_owner(job_id)

    assert {:error, :sandbox_owner_ensure_timeout} =
             OpenShellJobSandbox.ensure(job_id, %{})

    refute Process.alive?(pid)
    assert_eventually(fn -> Registry.lookup(MirrorNeuron.Sandbox.Registry, job_id) == [] end)
  end

  defp start_unresponsive_owner(key) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _value} = Registry.register(MirrorNeuron.Sandbox.Registry, key, nil)
        send(parent, {:sandbox_owner_registered, self()})

        receive do
          {:"$gen_call", _from, _request} -> Process.sleep(:infinity)
        end
      end)

    assert_receive {:sandbox_owner_registered, ^pid}
    pid
  end

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    started_at = System.monotonic_time(:millisecond)
    do_assert_eventually(fun, started_at, timeout_ms)
  end

  defp do_assert_eventually(fun, started_at, timeout_ms) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) - started_at > timeout_ms ->
        flunk("condition was not met before timeout")

      true ->
        Process.sleep(10)
        do_assert_eventually(fun, started_at, timeout_ms)
    end
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
