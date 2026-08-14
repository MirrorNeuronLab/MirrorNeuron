defmodule MirrorNeuron.Sandbox.OpenShellCLI do
  @moduledoc false

  def command_env do
    base = [{"NO_COLOR", "1"}]

    case System.get_env("OPENSHELL_GATEWAY_ENDPOINT") do
      endpoint when is_binary(endpoint) ->
        case String.trim(endpoint) do
          "" ->
            base

          endpoint ->
            [
              {"OPENSHELL_GATEWAY", nil},
              {"OPENSHELL_GATEWAY_ENDPOINT", endpoint}
              | base
            ]
        end

      _other ->
        base
    end
  end

  def direct_exec_args(sandbox_name, command) when is_list(command) do
    case direct_endpoint() do
      nil ->
        nil

      _endpoint ->
        command = encode_multiline_shell_command(command)
        ["sandbox", "exec", "--name", sandbox_name, "--no-tty", "--" | command]
    end
  end

  def run_with_closed_stdin(executable, args) when is_list(args) do
    {output, exit_code} =
      System.cmd(
        "/bin/sh",
        ["-c", ~S(exec </dev/null; exec "$@"), "openshell", executable | args],
        stderr_to_stdout: true,
        env: command_env()
      )

    {:ok, output, exit_code}
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  defp direct_endpoint do
    case System.get_env("OPENSHELL_GATEWAY_ENDPOINT") do
      endpoint when is_binary(endpoint) ->
        case String.trim(endpoint) do
          "" -> nil
          endpoint -> endpoint
        end

      _other ->
        nil
    end
  end

  defp encode_multiline_shell_command(["bash", "-lc", script]) do
    if String.contains?(script, ["\n", "\r"]) do
      encoded = Base.encode64(script)
      ["bash", "-lc", "printf %s '#{encoded}' | base64 -d | bash"]
    else
      ["bash", "-lc", script]
    end
  end

  defp encode_multiline_shell_command(command), do: command
end
