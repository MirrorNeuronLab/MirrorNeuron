defmodule MirrorNeuron.Sandbox.OpenShellCLITest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Sandbox.OpenShellCLI

  setup do
    gateway = System.get_env("OPENSHELL_GATEWAY")
    endpoint = System.get_env("OPENSHELL_GATEWAY_ENDPOINT")

    on_exit(fn ->
      restore_env("OPENSHELL_GATEWAY", gateway)
      restore_env("OPENSHELL_GATEWAY_ENDPOINT", endpoint)
    end)
  end

  test "direct endpoint removes an inherited gateway selector" do
    System.put_env("OPENSHELL_GATEWAY", "http://127.0.0.1:58080")
    System.put_env("OPENSHELL_GATEWAY_ENDPOINT", "http://127.0.0.1:58080")

    assert OpenShellCLI.command_env() == [
             {"OPENSHELL_GATEWAY", nil},
             {"OPENSHELL_GATEWAY_ENDPOINT", "http://127.0.0.1:58080"},
             {"NO_COLOR", "1"}
           ]
  end

  test "direct endpoint uses the gRPC sandbox exec transport" do
    System.put_env("OPENSHELL_GATEWAY_ENDPOINT", "http://127.0.0.1:58080")

    assert OpenShellCLI.direct_exec_args("sandbox-1", ["bash", "-lc", "echo ok"]) == [
             "sandbox",
             "exec",
             "--name",
             "sandbox-1",
             "--no-tty",
             "--",
             "bash",
             "-lc",
             "echo ok"
           ]
  end

  test "direct exec subprocess receives closed stdin" do
    assert OpenShellCLI.run_with_closed_stdin("/bin/sh", [
             "-c",
             "if read -r _value; then printf open; else printf closed; fi"
           ]) == {:ok, "closed", 0}
  end

  test "direct exec encodes multiline shell scripts as newline-free arguments" do
    System.put_env("OPENSHELL_GATEWAY_ENDPOINT", "http://127.0.0.1:58080")

    args = OpenShellCLI.direct_exec_args("sandbox-1", ["bash", "-lc", "printf 'ok\\n'\n"])
    command = Enum.drop(args, 6)

    assert Enum.all?(args, &(not String.contains?(&1, ["\n", "\r"])))
    assert System.cmd(hd(command), tl(command)) == {"ok\n", 0}
  end

  test "registered gateway selection remains available without a direct endpoint" do
    System.put_env("OPENSHELL_GATEWAY", "remote-team")
    System.delete_env("OPENSHELL_GATEWAY_ENDPOINT")

    assert OpenShellCLI.command_env() == [{"NO_COLOR", "1"}]
    assert OpenShellCLI.direct_exec_args("sandbox-1", ["true"]) == nil
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
