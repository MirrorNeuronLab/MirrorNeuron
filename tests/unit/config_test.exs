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

    bin_dir = Path.join([tmp_dir, ".local", "bin"])
    tool_path = Path.join(bin_dir, "test-tool")

    try do
      File.mkdir_p!(bin_dir)
      File.write!(tool_path, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(tool_path, 0o755)

      System.put_env("HOME", tmp_dir)
      System.put_env("PATH", "/usr/bin:/bin")
      System.delete_env("MIRROR_NEURON_TEST_TOOL_BIN")
      Application.put_env(:mirror_neuron, :test_tool_bin, "test-tool")

      assert Config.executable("MIRROR_NEURON_TEST_TOOL_BIN", :test_tool_bin) == tool_path
    after
      restore_env("HOME", previous_home)
      restore_env("PATH", previous_path)

      if previous_value == nil do
        Application.delete_env(:mirror_neuron, :test_tool_bin)
      else
        Application.put_env(:mirror_neuron, :test_tool_bin, previous_value)
      end

      File.rm_rf!(tmp_dir)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
