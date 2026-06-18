defmodule MirrorNeuron.ConfigTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Config

  test "executable resolves commands installed in common user bin directories" do
    previous_home = System.get_env("HOME")
    previous_path = System.get_env("PATH")
    previous_value = Application.get_env(:mirror_neuron, :test_tool_bin)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_config_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    bin_dir = Path.join([tmp_dir, ".local", "bin"])
    tool_path = Path.join(bin_dir, "test-tool")

    try do
      File.mkdir_p!(bin_dir)
      File.write!(tool_path, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(tool_path, 0o755)

      System.put_env("HOME", tmp_dir)
      System.put_env("PATH", "/usr/bin:/bin")
      System.delete_env("MN_TEST_TOOL_BIN")
      Application.put_env(:mirror_neuron, :test_tool_bin, "test-tool")

      assert Config.executable("MN_TEST_TOOL_BIN", :test_tool_bin) == tool_path
    after
      restore_env("HOME", previous_home)
      restore_env("PATH", previous_path)

      if previous_value == nil do
        Application.delete_env(:mirror_neuron, :test_tool_bin)
      else
        Application.put_env(:mirror_neuron, :test_tool_bin, previous_value)
      end
    end
  end

  test "validate rejects invalid runtime control timing settings" do
    previous_job_call_timeout = System.get_env("MN_JOB_CALL_TIMEOUT_MS")
    previous_delivery_retry_attempts = System.get_env("MN_DELIVERY_RETRY_ATTEMPTS")
    previous_delivery_retry_interval = System.get_env("MN_DELIVERY_RETRY_INTERVAL_MS")

    try do
      System.put_env("MN_JOB_CALL_TIMEOUT_MS", "0")

      assert_raise ArgumentError, ~r/MN_JOB_CALL_TIMEOUT_MS/, fn ->
        Config.validate!()
      end

      System.delete_env("MN_JOB_CALL_TIMEOUT_MS")
      System.put_env("MN_DELIVERY_RETRY_ATTEMPTS", "-1")

      assert_raise ArgumentError, ~r/MN_DELIVERY_RETRY_ATTEMPTS/, fn ->
        Config.validate!()
      end

      System.delete_env("MN_DELIVERY_RETRY_ATTEMPTS")
      System.put_env("MN_DELIVERY_RETRY_INTERVAL_MS", "-1")

      assert_raise ArgumentError, ~r/MN_DELIVERY_RETRY_INTERVAL_MS/, fn ->
        Config.validate!()
      end
    after
      restore_env("MN_JOB_CALL_TIMEOUT_MS", previous_job_call_timeout)
      restore_env("MN_DELIVERY_RETRY_ATTEMPTS", previous_delivery_retry_attempts)
      restore_env("MN_DELIVERY_RETRY_INTERVAL_MS", previous_delivery_retry_interval)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
