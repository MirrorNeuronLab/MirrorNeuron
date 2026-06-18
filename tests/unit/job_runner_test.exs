defmodule MirrorNeuron.Runtime.JobRunnerTest do
  use ExUnit.Case, async: false

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

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  defp restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
