defmodule MirrorNeuron.Runner.OpenShell.Settings do
  @moduledoc "Stable sandbox names, invocation workspace paths and cleanup settings."

  alias MirrorNeuron.Config

  def build_sandbox_name(config, opts) do
    prefix = Map.get(config, "name_prefix", "mirror-neuron")
    job_id = Keyword.get(opts, :job_id, "job")
    agent_id = Keyword.get(opts, :agent_id, "agent")
    attempt = Keyword.get(opts, :attempt, 1)
    invocation = Keyword.get(opts, :invocation, 1)

    sanitized_base =
      [prefix, job_id, agent_id]
      |> Enum.join("-")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    digest =
      [prefix, job_id, agent_id, to_string(invocation)]
      |> Enum.join("|")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 10)

    suffix = "#{digest}-i#{invocation}-a#{attempt}"
    base_limit = max(63 - String.length(suffix) - 1, 0)

    sanitized_base
    |> String.slice(0, base_limit)
    |> String.trim("-")
    |> case do
      "" -> suffix
      base -> "#{base}-#{suffix}"
    end
  end

  def build_shared_remote_dir(config, opts) do
    root = Map.get(config, "sandbox_upload_path", "/sandbox/job")
    agent = sanitize_path_segment(Keyword.get(opts, :agent_id, "agent"))
    attempt = Keyword.get(opts, :attempt, 1)
    invocation = Keyword.get(opts, :invocation, 1)
    unique = Integer.to_string(System.unique_integer([:positive]))

    if persistent_workspace?(config) do
      Path.join([root, "agents", agent])
    else
      Path.join([root, "runs", agent, "i#{invocation}-a#{attempt}-#{unique}"])
    end
  end

  @doc false
  def resolve_workdir(config, remote_dir) do
    default_root = Map.get(config, "sandbox_upload_path", "/sandbox/job")
    configured = Map.get(config, "workdir", remote_dir)

    cond do
      configured == default_root ->
        remote_dir

      String.starts_with?(configured, default_root <> "/") ->
        suffix = String.replace_prefix(configured, default_root, "")
        remote_dir <> suffix

      true ->
        configured
    end
  end

  def reuse_shared_sandbox?(config), do: Map.get(config, "reuse_shared_sandbox", true)

  defp persistent_workspace?(config), do: Map.get(config, "persistent_workspace", false)

  def cleanup_remote_dir?(config) do
    Map.get(config, "cleanup_remote_dir", not persistent_workspace?(config))
  end

  def sandbox_cli(config) do
    Map.get(
      config,
      "sandbox_cli",
      Config.executable("MN_OPENSHELL_BIN", :openshell_bin)
    )
  end

  defp sanitize_path_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
  end
end
