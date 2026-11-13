defmodule MirrorNeuron.Runner.OpenShell.Transport do
  @moduledoc "Closed-stdin CLI and SSH transport with streamed activity and command budgets."

  alias MirrorNeuron.Config
  alias MirrorNeuron.Sandbox.OpenShellCLI
  alias MirrorNeuron.Runner.OpenShell.Settings

  defp run_command(executable, args) do
    {output, exit_code} =
      System.cmd(executable, args,
        stderr_to_stdout: true,
        env: OpenShellCLI.command_env()
      )

    {:ok, output, exit_code}
  rescue
    error in ErlangError ->
      {:error, "failed to invoke #{executable}: #{Exception.message(error)}"}
  end

  @doc false
  def run_ssh_command(config, sandbox_name, ssh_host, command, opts \\ nil) do
    executable = Settings.sandbox_cli(config)

    case OpenShellCLI.direct_exec_args(sandbox_name, command) do
      nil ->
        run_registered_gateway_ssh(config, executable, sandbox_name, ssh_host, command, opts)

      args ->
        if is_list(opts),
          do: stream_transport(executable, args, config, opts),
          else: OpenShellCLI.run_with_closed_stdin(executable, args)
    end
  end

  defp run_registered_gateway_ssh(config, executable, sandbox_name, ssh_host, command, opts) do
    ssh_bin = Map.get(config, "ssh_bin", "ssh")

    temp_config =
      Path.join(
        Config.string("MN_TEMP_DIR", :temp_dir),
        "mirror_neuron_ssh_#{System.unique_integer([:positive])}"
      )

    try do
      case System.cmd(executable, ["sandbox", "ssh-config", sandbox_name],
             stderr_to_stdout: true,
             env: OpenShellCLI.command_env()
           ) do
        {ssh_config, 0} ->
          File.write!(temp_config, ssh_config)
          args = ["-F", temp_config, ssh_host | command]

          if is_list(opts),
            do: stream_transport(ssh_bin, args, config, opts),
            else: run_command(ssh_bin, args)

        {output, exit_code} ->
          {:error,
           %{
             "error" => "failed to resolve shared sandbox ssh config",
             "sandbox_name" => sandbox_name,
             "exit_code" => exit_code,
             "logs" => output
           }}
      end
    after
      File.rm_rf(temp_config)
    end
  rescue
    error in ErlangError ->
      {:error, "failed to invoke ssh for #{sandbox_name}: #{Exception.message(error)}"}
  end

  def stream_transport(executable, args, config, opts) do
    command = ["/bin/sh", "-c", ~S(exec </dev/null; exec "$@"), "openshell", executable | args]
    limits = config["artifact_handoff"] || %{}

    transport =
      config
      |> Map.put("max_output_bytes", 4 * Map.get(limits, "max_result_bytes", 1_000_000) + 16_384)
      |> Map.put("beacon_enabled", true)
      |> Map.put("agent_beacon_required", false)

    case MirrorNeuron.Runner.HostLocal.stream_command(
           command,
           OpenShellCLI.command_env(),
           File.cwd!(),
           transport,
           opts
         ) do
      {:ok, output, code} -> {:ok, output, code}
      other -> other
    end
  end
end
