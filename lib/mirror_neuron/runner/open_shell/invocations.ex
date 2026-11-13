defmodule MirrorNeuron.Runner.OpenShell.Invocations do
  @moduledoc "Owns one-shot sandbox leases and shared sandbox invocation cleanup."

  require Logger

  alias MirrorNeuron.Runner.OpenShell.Command
  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Sandbox.OpenShellJobSandbox
  alias MirrorNeuron.Runner.OpenShell.Output
  alias MirrorNeuron.Runner.OpenShell.Settings
  alias MirrorNeuron.Runner.OpenShell.Transport
  alias MirrorNeuron.Runner.OpenShell.Uploads
  alias MirrorNeuron.Runner.OpenShell.Workspace

  def run_one_shot(payload, config, opts) do
    sandbox_name = Settings.build_sandbox_name(config, opts)
    executable = Settings.sandbox_cli(config)
    remote_dir = Map.get(config, "sandbox_upload_path", "/sandbox/job")

    with {:ok, staged_dir} <- Workspace.stage_workspace(payload, config, opts) do
      try do
        with {:ok, resource_id} <- register_one_shot_sandbox(sandbox_name, opts),
             {:ok, args} <- Command.build_args(sandbox_name, staged_dir, remote_dir, config, opts),
             {:ok, output, openshell_exit_code} <-
               Transport.stream_transport(executable, args, config, opts),
             :ok <-
               release_one_shot_sandbox(
                 resource_id,
                 Map.get(config, "no_keep", true),
                 openshell_exit_code
               ),
             {:ok, result} <-
               Output.extract_result(output, sandbox_name, remote_dir, openshell_exit_code) do
          if result["exit_code"] == 0 do
            {:ok, result}
          else
            {:error, result}
          end
        end
      after
        File.rm_rf(staged_dir)
      end
    end
  end

  defp register_one_shot_sandbox(sandbox_name, opts) do
    attrs = %{
      "operation" => "register",
      "resource_kind" => "openshell",
      "scope" => "attempt",
      "external_id" => sandbox_name,
      "job_id" => to_string(Keyword.get(opts, :job_id) || ""),
      "run_id" => to_string(Keyword.get(opts, :run_id) || ""),
      "owner_node" => to_string(Node.self()),
      "state" => "committed"
    }

    case ModelServices.native_resource_command(attrs) do
      {:ok, %{"resource_id" => resource_id}} when is_binary(resource_id) ->
        {:ok, resource_id}

      {:ok, _result} ->
        {:error, "native SDK did not return an OpenShell resource lease"}

      {:error, reason} ->
        {:error, "failed to register OpenShell sandbox ownership: #{reason}"}
    end
  end

  defp release_one_shot_sandbox(resource_id, true, 0) do
    case ModelServices.native_resource_command(%{
           "operation" => "release",
           "resource_ids" => [resource_id]
         }) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "OpenShell sandbox completed but its native resource lease could not be released: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp release_one_shot_sandbox(_resource_id, _no_keep, _openshell_exit_code), do: :ok

  def run_in_shared_sandbox(payload, config, opts) do
    executable = Settings.sandbox_cli(config)

    with {:ok, sandbox} <- OpenShellJobSandbox.ensure(Keyword.fetch!(opts, :job_id), config) do
      remote_dir = Settings.build_shared_remote_dir(config, opts)

      prepared_config = Map.put(config, "sandbox_name", sandbox["sandbox_name"])

      with {:ok, staged_dir} <- Workspace.stage_workspace(payload, prepared_config, opts) do
        try do
          with {:ok, :uploaded} <-
                 Uploads.upload_workspace(
                   executable,
                   sandbox["sandbox_name"],
                   staged_dir,
                   remote_dir
                 ),
               {:ok, command} <- Command.build_command(prepared_config, remote_dir, opts),
               {:ok, output, ssh_exit_code} <-
                 Transport.run_ssh_command(
                   prepared_config,
                   sandbox["sandbox_name"],
                   sandbox["ssh_host"],
                   command,
                   opts
                 ),
               {:ok, result} <-
                 Output.extract_result(output, sandbox["sandbox_name"], remote_dir, ssh_exit_code) do
            if result["exit_code"] == 0, do: {:ok, result}, else: {:error, result}
          end
        after
          File.rm_rf(staged_dir)
        end
      end
    end
  end
end
