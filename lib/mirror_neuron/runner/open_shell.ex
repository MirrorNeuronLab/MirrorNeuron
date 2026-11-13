defmodule MirrorNeuron.Runner.OpenShell do
  @behaviour MirrorNeuron.Runner
  @impl true
  def control_profile(config) do
    profile = MirrorNeuron.Runner.ControlProfile.sdk(config)
    %{profile | restart_after_stop: false}
  end

  @moduledoc "OpenShell runner selection and stable staging/transport entrypoints."

  alias MirrorNeuron.Runner.OpenShell.Invocations
  alias MirrorNeuron.Sandbox.OpenShellJobSandbox
  alias MirrorNeuron.Runner.OpenShell.PolicyPaths
  alias MirrorNeuron.Runner.OpenShell.Settings
  alias MirrorNeuron.Runner.OpenShell.Transport
  alias MirrorNeuron.Runner.OpenShell.Uploads
  alias MirrorNeuron.Runner.OpenShell.Workspace

  @doc false
  defdelegate upload_workspace(executable, sandbox_name, staged_dir, remote_dir), to: Uploads
  @doc false
  defdelegate run_ssh_command(config, sandbox_name, ssh_host, command), to: Transport
  @doc false
  defdelegate run_ssh_command(config, sandbox_name, ssh_host, command, opts), to: Transport
  @doc false
  defdelegate stage_workspace(payload, config, opts), to: Workspace
  @doc false
  defdelegate resolve_workdir(config, remote_dir), to: Settings

  @impl true
  def stop_commands(job_id, :all), do: OpenShellJobSandbox.cleanup_job_local(job_id)

  def stop_commands(_job_id, _agents), do: :ok

  @impl true
  def run(payload, config, opts \\ []) do
    config = PolicyPaths.resolve_local_cli_paths(config, opts)

    with :ok <- MirrorNeuron.Runner.OpenShellArtifactHandoff.validate(config) do
      cond do
        is_map(config["artifact_handoff"]) ->
          MirrorNeuron.Runner.OpenShellArtifactHandoff.run(payload, config, opts)

        Settings.reuse_shared_sandbox?(config) ->
          Invocations.run_in_shared_sandbox(payload, config, opts)

        true ->
          Invocations.run_one_shot(payload, config, opts)
      end
    end
  end
end
