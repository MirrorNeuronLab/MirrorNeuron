defmodule MirrorNeuron.Runtime.AgentWorker.Context do
  @moduledoc "Materializes a worker bundle and injects its allocated runtime environment."

  require Logger

  alias MirrorNeuron.Bundle.Archive, as: BundleArchive
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Scheduler

  def inject_runtime_paths(node, runtime_context) do
    allocation =
      runtime_context[:allocation] ||
        Scheduler.allocation(runtime_context[:scheduler], node.node_id)

    runtime_config =
      node.config
      |> Map.put("__bundle_root", runtime_context[:bundle_root])
      |> Map.put("__manifest_path", runtime_context[:manifest_path])
      |> Map.put("__payloads_path", runtime_context[:payloads_path])
      |> Map.put("__artifact_refs", runtime_context[:artifact_refs] || [])
      |> Map.put("__mirror_neuron_allocation", allocation)
      |> put_artifact_environment(runtime_context[:artifact_refs] || [])
      |> put_allocation_environment(allocation)
      |> put_runtime_environment(runtime_context[:runtime_env] || %{})

    %{node | config: runtime_config}
  end

  def materialize_runtime_bundle_context(runtime_context) when is_map(runtime_context) do
    if local_bundle_available?(runtime_context[:bundle_root]) do
      runtime_context
    else
      runtime_context
      |> bundle_fingerprint()
      |> load_archived_bundle(runtime_context)
    end
  end

  def materialize_runtime_bundle_context(runtime_context), do: runtime_context

  defp local_bundle_available?(path) when is_binary(path) and path != "" do
    File.dir?(path)
  end

  defp local_bundle_available?(_path), do: false

  defp bundle_fingerprint(runtime_context) do
    manifest_ref = runtime_context[:manifest_ref]

    cond do
      is_map(manifest_ref) ->
        Map.get(manifest_ref, "bundle_fingerprint") || Map.get(manifest_ref, :bundle_fingerprint)

      true ->
        nil
    end
  end

  defp load_archived_bundle(fingerprint, runtime_context)
       when is_binary(fingerprint) and fingerprint != "" do
    case BundleArchive.load(fingerprint) do
      {:ok, bundle} ->
        runtime_context
        |> Map.put(:bundle_root, bundle.root_path)
        |> Map.put(:manifest_path, bundle.manifest_path)
        |> Map.put(:payloads_path, bundle.payloads_path)

      {:error, reason} ->
        Logger.warning("failed to materialize runtime bundle for remote agent",
          fingerprint: fingerprint,
          reason: inspect(reason)
        )

        runtime_context
    end
  end

  defp load_archived_bundle(_fingerprint, runtime_context), do: runtime_context

  defp put_allocation_environment(config, allocation) do
    allocation_env = ResourceSpec.allocation_env(allocation)

    Map.update(config, "environment", allocation_env, fn
      env when is_map(env) -> Map.merge(env, allocation_env)
      _env -> allocation_env
    end)
  end

  defp put_artifact_environment(config, artifact_refs) do
    artifact_env = %{"MN_ARTIFACTS_JSON" => Jason.encode!(artifact_refs || [])}

    Map.update(config, "environment", artifact_env, fn
      env when is_map(env) -> Map.merge(env, artifact_env)
      _env -> artifact_env
    end)
  end

  defp put_runtime_environment(config, runtime_env) when is_map(runtime_env) do
    runtime_env =
      runtime_env
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Map.new()

    Map.update(config, "environment", runtime_env, fn
      env when is_map(env) -> Map.merge(env, runtime_env)
      _env -> runtime_env
    end)
  end

  defp put_runtime_environment(config, _runtime_env), do: config

  def recovery_flag?(snapshot, string_key, atom_key) when is_map(snapshot) do
    Map.get(snapshot, string_key, Map.get(snapshot, atom_key, false)) == true
  end

  def recovery_flag?(_snapshot, _string_key, _atom_key), do: false
end
