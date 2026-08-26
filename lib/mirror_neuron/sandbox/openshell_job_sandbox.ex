defmodule MirrorNeuron.Sandbox.OpenShellJobSandbox do
  @moduledoc false

  def ensure(job_id, config), do: prepared_sandbox(job_id, config)

  def cleanup_job_local(_job_id, _config \\ %{}), do: :ok

  defp prepared_sandbox(job_id, config) do
    sandbox_name =
      Map.get(config, "sandbox_name") ||
        Map.get(config, "openshell_sandbox_name") ||
        System.get_env("MN_OPENSHELL_SANDBOX_NAME")

    ssh_host =
      Map.get(config, "ssh_host") ||
        Map.get(config, "openshell_ssh_host") ||
        System.get_env("MN_OPENSHELL_SSH_HOST")

    if is_binary(sandbox_name) and sandbox_name != "" do
      {:ok,
       %{
         "sandbox_name" => sandbox_name,
         "ssh_host" => ssh_host || "openshell-#{sandbox_name}"
       }}
    else
      {:error,
       "OpenShell sandbox for job #{job_id} is not prepared; prepare OpenShell resources with mn-python-sdk/API/CLI and provide sandbox_name or MN_OPENSHELL_SANDBOX_NAME"}
    end
  end
end
