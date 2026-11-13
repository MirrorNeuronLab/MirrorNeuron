defmodule MirrorNeuron.Runner.HostLocal.Paths do
  @moduledoc "Constrains upload and dependency paths to their declared workspace roots."

  def resolve_upload_source(source, nil), do: {:ok, Path.expand(source)}

  def resolve_upload_source(source, payloads_path) do
    payloads_root = Path.expand(payloads_path)

    resolved =
      if Path.type(source) == :absolute do
        Path.expand(source)
      else
        Path.expand(source, payloads_root)
      end

    if inside_path?(resolved, payloads_root) do
      {:ok, resolved}
    else
      {:error, "upload source must stay inside blueprint payloads: #{source}"}
    end
  end

  def resolve_upload_target(base_dir, target) do
    resolved = Path.expand(target, base_dir)

    if inside_path?(resolved, Path.expand(base_dir)) do
      {:ok, resolved}
    else
      {:error, "upload target must stay inside sandbox workspace: #{target}"}
    end
  end

  def inside_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  def safe_relative_path?(path) when is_binary(path) do
    Path.type(path) == :relative and
      ".." not in Path.split(path) and
      not String.starts_with?(path, "..") and
      not String.contains?(path, "/../") and
      path not in ["", "."]
  end

  def resolve_workdir(config, base_dir) do
    default_root = Map.get(config, "sandbox_upload_path", "/sandbox/job")
    configured = Map.get(config, "workdir", base_dir)

    cond do
      configured == default_root ->
        base_dir

      String.starts_with?(configured, default_root <> "/") ->
        suffix = String.replace_prefix(configured, default_root, "")
        base_dir <> suffix

      true ->
        configured
    end
  end
end
