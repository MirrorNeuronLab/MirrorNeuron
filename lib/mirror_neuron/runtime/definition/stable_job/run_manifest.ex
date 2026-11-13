defmodule MirrorNeuron.Runtime.StableJob.RunManifest do
  @moduledoc "Binds run identity and configuration while preserving definition-scoped storage paths."

  alias MirrorNeuron.Runtime.StableJob.DataAccess
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.StableJob.Values

  @definition_scoped_keys ~w(
    submission_id submission_path host_submission_path
    docker_worker_container_name docker_worker_compose_service
    container_name service
    MN_STORAGE_SUBMISSION_ID MN_JOB_SHARED_STORAGE_ROOT
    MN_JOB_INPUT_DIR MN_JOB_OUTPUT_DIR MN_RUNS_ROOT
  )
  @run_identity_keys ~w(
    run_id blueprint_run_id MN_RUN_ID MN_ATTEMPT_ID
  )
  @run_output_keys ~w(
    run_dir run_path blueprint_run_dir MN_RUN_DIR
  )

  @doc false
  def prepare_run_manifest(manifest, definition, run_id, data_dir, access, opts \\ []) do
    previous_run_id =
      get_in(manifest.metadata || %{}, ["run_id"]) ||
        get_in(manifest.metadata || %{}, ["blueprint_run_id"])

    with {:ok, manifest} <- rebind_run_manifest(manifest, previous_run_id, run_id) do
      do_with_run_identity(manifest, definition, run_id, data_dir, access, opts)
    end
  end

  defp do_with_run_identity(manifest, definition, run_id, data_dir, access, opts) do
    protected_input_paths = staged_input_config_paths(manifest)

    resolved_configuration =
      definition["resolved_configuration"]
      |> Values.stringify()
      |> drop_runtime_owned_paths(protected_input_paths)

    run_input_overrides =
      opts
      |> Keyword.get(:inputs, %{})
      |> Values.stringify()
      |> drop_runtime_owned_paths(protected_input_paths)

    metadata =
      (manifest.metadata || %{})
      |> Values.stringify()
      |> Map.merge(%{
        "job_id" => definition["job_id"],
        "run_id" => run_id,
        "job_data_access" => access,
        "data_generation" => definition["data_generation"]
      })
      |> Map.put("queued_definition", %{
        "bundle_fingerprint" => get_in(definition, ["bundle_ref", "bundle_fingerprint"]),
        "configuration_hash" =>
          :crypto.hash(:sha256, :erlang.term_to_binary(definition["resolved_configuration"]))
          |> Base.encode16(case: :lower)
      })
      |> Values.maybe_put("schedule_dispatch", Keyword.get(opts, :schedule_metadata))
      |> Values.maybe_put("run_start_request", Keyword.get(opts, :start_request_identity))

    environment = %{
      "MN_JOB_ID" => definition["job_id"],
      "MN_RUN_ID" => run_id,
      "MN_JOB_DATA_DIR" => data_dir,
      "MN_JOB_DATA_ACCESS" => access,
      "MN_JOB_DATA_GENERATION" => to_string(definition["data_generation"]),
      "MN_ATTEMPT_ID" => "#{run_id}:1"
    }

    nodes =
      Enum.map(manifest.nodes, fn node ->
        config = Map.get(node, :config, %{})

        requested_access =
          if access == "read" do
            "read"
          else
            config
            |> Map.get("job_data_access", access)
            |> DataAccess.normalize_job_data_access()
          end

        env =
          Map.get(config, "environment", %{})
          |> merge_runtime_configuration(definition, run_id, protected_input_paths)
          |> Map.merge(Map.put(environment, "MN_JOB_DATA_ACCESS", requested_access))

        %{node | config: Map.put(config, "environment", env)}
      end)

    initial_inputs =
      (manifest.initial_inputs || %{})
      |> Values.deep_merge(resolved_configuration)
      |> Values.deep_merge(run_input_overrides)
      |> Values.deep_merge(%{
        "identity" => %{"job_id" => definition["job_id"], "run_id" => run_id}
      })

    {:ok, %{manifest | metadata: metadata, nodes: nodes, initial_inputs: initial_inputs}}
  end

  defp rebind_run_manifest(manifest, previous_run_id, run_id)
       when is_binary(previous_run_id) and previous_run_id != "" and previous_run_id != run_id do
    manifest
    |> Manifest.to_map()
    |> rebind_run_value(previous_run_id, run_id)
    |> Manifest.load()
  end

  defp rebind_run_manifest(manifest, _previous_run_id, _run_id), do: {:ok, manifest}

  defp rebind_run_value(value, previous_run_id, run_id) when is_map(value) do
    Map.new(value, fn {key, child} ->
      {key, rebind_run_child(to_string(key), child, previous_run_id, run_id)}
    end)
  end

  defp rebind_run_value(value, previous_run_id, run_id) when is_list(value),
    do: Enum.map(value, &rebind_run_value(&1, previous_run_id, run_id))

  defp rebind_run_value(value, _previous_run_id, _run_id), do: value

  defp rebind_run_child(key, child, _previous_run_id, _run_id)
       when is_binary(key) and key in @definition_scoped_keys,
       do: child

  defp rebind_run_child("MN_BLUEPRINT_CONFIG_JSON", child, previous_run_id, run_id)
       when is_binary(child) do
    case Jason.decode(child) do
      {:ok, config} when is_map(config) ->
        config
        |> rebind_blueprint_config(previous_run_id, run_id)
        |> Jason.encode!()

      _invalid ->
        child
    end
  end

  defp rebind_run_child("output_copy", child, previous_run_id, run_id)
       when is_list(child) do
    Enum.map(child, &rebind_output_copy_spec(&1, previous_run_id, run_id))
  end

  defp rebind_run_child(key, child, previous_run_id, run_id)
       when is_binary(key) and key in @run_output_keys and is_binary(child) do
    replace_terminal_path_segment(child, previous_run_id, run_id)
  end

  defp rebind_run_child(key, child, previous_run_id, run_id)
       when is_binary(key) and key in @run_identity_keys and is_binary(child),
       do: String.replace(child, previous_run_id, run_id)

  defp rebind_run_child(_key, child, previous_run_id, run_id),
    do: rebind_run_value(child, previous_run_id, run_id)

  defp rebind_blueprint_config(value, previous_run_id, run_id) when is_map(value) do
    Map.new(value, fn {key, child} ->
      key = to_string(key)

      rebound =
        cond do
          key in @definition_scoped_keys ->
            child

          key in @run_identity_keys and is_binary(child) ->
            String.replace(child, previous_run_id, run_id)

          key in @run_output_keys and is_binary(child) ->
            replace_terminal_path_segment(child, previous_run_id, run_id)

          true ->
            rebind_blueprint_config(child, previous_run_id, run_id)
        end

      {key, rebound}
    end)
  end

  defp rebind_blueprint_config(value, previous_run_id, run_id) when is_list(value),
    do: Enum.map(value, &rebind_blueprint_config(&1, previous_run_id, run_id))

  defp rebind_blueprint_config(value, _previous_run_id, _run_id), do: value

  defp rebind_output_copy_spec(value, previous_run_id, run_id) when is_map(value) do
    Map.new(value, fn {key, child} ->
      if to_string(key) in ["source_path", "target_path"] and is_binary(child) do
        {key, replace_terminal_path_segment(child, previous_run_id, run_id)}
      else
        {key, child}
      end
    end)
  end

  defp rebind_output_copy_spec(value, _previous_run_id, _run_id), do: value

  defp replace_terminal_path_segment(value, previous_run_id, run_id) do
    suffix = "/" <> previous_run_id

    if String.ends_with?(value, suffix) do
      String.replace_suffix(value, suffix, "/" <> run_id)
    else
      value
    end
  end

  defp merge_runtime_configuration(environment, definition, run_id, protected_input_paths) do
    case Map.get(environment, "MN_BLUEPRINT_CONFIG_JSON") do
      encoded when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, config} when is_map(config) ->
            config =
              config
              |> Values.deep_merge(
                definition["resolved_configuration"]
                |> Values.stringify()
                |> drop_runtime_owned_paths(protected_input_paths)
              )
              |> Values.deep_merge(%{
                "identity" => %{"job_id" => definition["job_id"], "run_id" => run_id}
              })

            Map.put(environment, "MN_BLUEPRINT_CONFIG_JSON", Jason.encode!(config))

          _invalid ->
            environment
        end

      _missing ->
        environment
    end
  end

  # Local input folders are copied to a submission-scoped shared-storage path
  # before a run starts.  The SDK advertises those exact config paths in
  # mn_storage; they are runtime-owned from that point forward, so a persisted
  # launch overlay containing a submitter-only /Users/... path must not win.

  defp staged_input_config_paths(manifest) do
    manifest
    |> Map.get(:metadata, %{})
    |> Map.get("mn_storage", %{})
    |> Map.get("inputs", %{})
    |> Map.get("folders", [])
    |> List.wrap()
    |> Enum.flat_map(fn folder ->
      if is_map(folder) do
        [Map.get(folder, "config_path") | List.wrap(Map.get(folder, "config_paths"))]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  defp drop_runtime_owned_paths(configuration, paths) when is_map(configuration) do
    Enum.reduce(paths, configuration, &drop_dotted_path(&2, &1))
  end

  defp drop_runtime_owned_paths(configuration, _paths), do: configuration

  defp drop_dotted_path(configuration, path) when is_map(configuration) and is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> drop_path_segments(configuration)
  end

  defp drop_dotted_path(configuration, _path), do: configuration

  defp drop_path_segments([], configuration), do: configuration

  defp drop_path_segments([key], configuration), do: Map.delete(configuration, key)

  defp drop_path_segments([key | rest], configuration) do
    case Map.get(configuration, key) do
      value when is_map(value) ->
        updated = drop_path_segments(rest, value)

        if map_size(updated) == 0,
          do: Map.delete(configuration, key),
          else: Map.put(configuration, key, updated)

      _ ->
        configuration
    end
  end
end
