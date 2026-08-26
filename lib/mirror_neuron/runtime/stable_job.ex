defmodule MirrorNeuron.Runtime.StableJob do
  @moduledoc """
  Durable configured jobs and their execution runs.

  `job_id` identifies this record and its persistent data. Batch definitions
  retain one-to-many run history. A `type: service` definition retains exactly
  one attached run whose identity survives pause and resume.
  """

  alias MirrorNeuron.{JobBundle, JobData, JobId, Manifest}
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.JobResponse
  alias MirrorNeuron.Runtime.Page

  @terminal_statuses ["completed", "failed", "cancelled"]
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
  @start_gate_ttl_ms 600_000
  @start_gate_retries 50
  @start_gate_retry_ms 100

  def create(input, opts \\ []) do
    with {:ok, bundle} <- JobBundle.load(input),
         job_id <- Keyword.get(opts, :job_id) || stable_job_id(bundle.manifest.graph_id),
         :ok <- JobData.validate_id(job_id),
         {:ok, false} <- RedisStore.job_definition_exists?(job_id),
         {:ok, storage} <- storage_declarations(bundle, Keyword.get(opts, :storage, %{})),
         {:ok, seed_paths} <- seed_paths(bundle, storage),
         {:ok, data_dir} <- JobData.initialize(job_id, seed_paths) do
      now = Runtime.timestamp()

      definition = %{
        "job_id" => job_id,
        "blueprint_id" => blueprint_id(bundle.manifest),
        "graph_id" => bundle.manifest.graph_id,
        "job_name" => bundle.manifest.job_name,
        "type" => bundle.manifest.type,
        "manifest" => Manifest.to_map(bundle.manifest),
        "bundle_ref" => Runtime.bundle_ref(bundle.manifest, bundle),
        "resolved_configuration" => stringify(Keyword.get(opts, :resolved_configuration, %{})),
        "schedules" => stringify(Keyword.get(opts, :schedules, [])),
        "schedule_ids" => [],
        "storage" => storage,
        "owner_node" => to_string(Keyword.get(opts, :owner_node, NodeAdapter.self())),
        "status" => "active",
        "revision" => 1,
        "data_generation" => 1,
        "data_dir" => data_dir,
        "run_ids" => [],
        "created_at" => now,
        "updated_at" => now
      }

      persist_and_reconcile(job_id, definition)
    else
      {:ok, true} -> {:error, :job_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  def get(job_id), do: RedisStore.fetch_job_definition(job_id)

  def list(opts \\ []) do
    with {:ok, definitions} <- RedisStore.list_job_definitions() do
      include_archived = Keyword.get(opts, :include_archived, false)

      definitions =
        if include_archived,
          do: definitions,
          else: Enum.reject(definitions, &(&1["status"] == "archived"))

      {:ok, definitions}
    end
  end

  def list_page(opts \\ []) do
    include_archived = Keyword.get(opts, :include_archived, false)

    with {:ok, definitions} <- list(include_archived: include_archived) do
      Page.paginate(
        definitions,
        opts,
        "jobs",
        %{"include_archived" => include_archived},
        &{&1["created_at"] || "", &1["job_id"] || ""}
      )
    end
  end

  def update(job_id, attrs, opts \\ [])

  def update(job_id, attrs, opts) when is_map(attrs) do
    allowed = ~w(resolved_configuration schedules storage job_name)

    with_start_gate(job_id, fn ->
      with {:ok, definition} <- get(job_id),
           :ok <- ensure_revision(definition, Keyword.get(opts, :expected_revision)),
           {:ok, normalized_attrs} <- normalize_update(definition, stringify(attrs)) do
        updated =
          definition
          |> Map.merge(Map.take(normalized_attrs, allowed))
          |> increment_revision()
          |> Map.put("updated_at", Runtime.timestamp())

        persist_and_reconcile(job_id, updated)
      end
    end)
  end

  def update(_job_id, _attrs, _opts), do: {:error, :invalid_job_update}

  def replace_bundle(job_id, input, attrs \\ %{}, opts \\ [])

  def replace_bundle(job_id, input, attrs, opts) when is_map(attrs) do
    allowed = ~w(resolved_configuration schedules storage job_name)

    with_start_gate(job_id, fn ->
      with {:ok, definition} <- get(job_id),
           :ok <- ensure_revision(definition, Keyword.get(opts, :expected_revision)),
           :ok <- ensure_active(definition),
           :ok <- ensure_owner_node(definition),
           {:ok, bundle} <- JobBundle.load(input),
           :ok <- ensure_same_bundle_identity(definition, bundle),
           {:ok, normalized_attrs} <- normalize_update(definition, stringify(attrs)),
           {:ok, definition, replacement} <-
             prepare_bundle_replacement(definition, bundle, opts) do
        updated =
          definition
          |> Map.merge(Map.take(normalized_attrs, allowed))
          |> Map.merge(%{
            "blueprint_id" => blueprint_id(bundle.manifest),
            "graph_id" => bundle.manifest.graph_id,
            "job_name" => bundle.manifest.job_name,
            "type" => bundle.manifest.type,
            "manifest" => Manifest.to_map(bundle.manifest),
            "bundle_ref" => Runtime.bundle_ref(bundle.manifest, bundle),
            "updated_at" => Runtime.timestamp(),
            "revision" => (definition["revision"] || 0) + 1
          })

        case RedisStore.persist_job_definition(job_id, updated) do
          {:ok, saved} ->
            _ = JobResponse.definition_changed(saved)

            {:ok,
             Map.put(
               Map.merge(saved, replacement),
               "retired_definition_resources",
               definition_resource_descriptor(definition)
             )}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
  end

  def replace_bundle(_job_id, _input, _attrs, _opts), do: {:error, :invalid_job_update}

  def archive(job_id, opts \\ []) do
    with_start_gate(job_id, fn ->
      with {:ok, definition} <- get(job_id),
           :ok <- ensure_revision(definition, Keyword.get(opts, :expected_revision)) do
        if definition["status"] == "archived" do
          {:ok, definition}
        else
          with :ok <- ensure_no_active_runs(definition),
               :ok <- JobResponse.stop(definition),
               {:ok, archived} <-
                 RedisStore.persist_job_definition(
                   job_id,
                   definition |> Map.put("status", "archived") |> increment_revision()
                 ),
               :ok <- pause_job_schedules(job_id) do
            {:ok, archived}
          end
        end
      end
    end)
  end

  def start_run(job_id, opts \\ []) do
    case start_run_result(job_id, opts) do
      {:ok, result} -> {:ok, result.run_id, result.pid}
      {:error, _reason} = error -> error
    end
  end

  def start_run_result(job_id, opts \\ []) do
    with_start_gate(job_id, fn ->
      with {:ok, definition} <- get(job_id) do
        do_start_run_result(definition, opts)
      end
    end)
  end

  def scheduled_transition(job_id, opts \\ []) do
    with_start_gate(job_id, fn ->
      with {:ok, definition} <- get(job_id),
           :ok <- ensure_active(definition),
           :ok <- ensure_owner_node(definition) do
        if service_definition?(definition) do
          do_scheduled_service_transition(definition, opts)
        else
          do_start_run_result(definition, opts)
        end
      end
    end)
  end

  def list_runs(job_id) do
    with {:ok, definition} <- get(job_id) do
      definition
      |> Map.get("run_ids", [])
      |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, runs} ->
        case RedisStore.fetch_job(run_id) do
          {:ok, run} -> {:cont, {:ok, [normalize_run(run, job_id, run_id) | runs]}}
          {:error, _missing} -> {:cont, {:ok, runs}}
        end
      end)
      |> then(fn {:ok, runs} -> {:ok, Enum.reverse(runs)} end)
    end
  end

  def list_runs_page(job_id, opts \\ []) do
    with {:ok, runs} <- list_runs(job_id) do
      Page.paginate(
        runs,
        opts,
        "job-runs:#{job_id}",
        %{"job_id" => job_id},
        &{&1["submitted_at"] || &1["started_at"] || "", &1["run_id"] || ""}
      )
    end
  end

  def reset_data(job_id) do
    with_start_gate(job_id, fn ->
      with {:ok, definition} <- get(job_id),
           :ok <- ensure_no_active_runs(definition),
           :ok <- JobResponse.stop(definition),
           {:ok, bundle} <- load_bundle(definition),
           {:ok, seeds} <- seed_paths(bundle, definition["storage"] || %{}),
           {:ok, data_dir} <- JobData.reset(job_id, seeds) do
        updated =
          definition
          |> Map.update("data_generation", 2, &(&1 + 1))
          |> Map.put("data_dir", data_dir)

        persist_and_reconcile(job_id, updated)
      end
    end)
  end

  def delete(job_id, opts \\ []) do
    if Keyword.get(opts, :confirmed, false) do
      with_start_gate(job_id, fn ->
        with {:ok, definition} <- get(job_id),
             :ok <- ensure_revision(definition, Keyword.get(opts, :expected_revision)),
             :ok <- JobResponse.stop(definition),
             :ok <- delete_job_schedules(job_id),
             :ok <- delete_historical_runs(definition),
             :ok <- SharedStorage.cleanup_manifest(job_id, definition["manifest"]),
             :ok <- JobData.delete(job_id),
             :ok <- RedisStore.delete_job_definition(job_id) do
          {:ok, definition_resource_descriptor(definition)}
        end
      end)
    else
      {:error, :confirmation_required}
    end
  end

  def delete_run(run_id, opts \\ []) do
    if Keyword.get(opts, :confirmed, false) do
      with {:ok, run} <- RedisStore.fetch_job(run_id),
           stable_job_id <-
             run["stable_job_id"] || get_in(run, ["manifest", "metadata", "job_id"]),
           {:ok, _cleanup} <- cleanup_run(run_id),
           :ok <- detach_run(stable_job_id, run_id) do
        :ok
      end
    else
      {:error, :confirmation_required}
    end
  end

  def attach_schedule(job_id, schedule_id) do
    with_start_gate(job_id, fn ->
      with {:ok, definition} <- get(job_id) do
        updated =
          Map.update(definition, "schedule_ids", [schedule_id], &Enum.uniq(&1 ++ [schedule_id]))

        RedisStore.persist_job_definition(job_id, updated)
      end
    end)
  end

  defp attach_run(definition, run_id) do
    updated =
      definition
      |> Map.update("run_ids", [run_id], &Enum.uniq(&1 ++ [run_id]))
      |> Map.put("latest_run_id", run_id)
      |> increment_revision()

    RedisStore.persist_job_definition(definition["job_id"], updated)
  end

  defp increment_revision(definition) do
    Map.update(definition, "revision", 1, &(&1 + 1))
  end

  defp persist_and_reconcile(job_id, definition) do
    case RedisStore.persist_job_definition(job_id, definition) do
      {:ok, saved} = result ->
        _ = JobResponse.definition_changed(saved)
        result

      error ->
        error
    end
  end

  defp ensure_revision(_definition, nil), do: :ok
  defp ensure_revision(_definition, 0), do: :ok

  defp ensure_revision(definition, expected) when is_integer(expected) do
    if definition["revision"] == expected,
      do: :ok,
      else: {:error, :revision_mismatch}
  end

  defp ensure_revision(_definition, _expected), do: {:error, :invalid_revision}

  defp ensure_run_id_available(run_id) do
    case RedisStore.execution_exists?(run_id) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :run_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_start_run_result(definition, opts) do
    replace_existing = Keyword.get(opts, :replace_existing_run, false)
    service = service_definition?(definition)
    existing_run_ids = definition |> Map.get("run_ids", []) |> Enum.uniq()
    requested_run_id = Keyword.get(opts, :run_id)

    with :ok <- ensure_replacement_scope(service, replace_existing),
         {:replay, replay} <-
           replacement_replay(definition, requested_run_id, replace_existing) do
      {:ok, replay}
    else
      :continue ->
        do_start_new_run(
          definition,
          opts,
          service,
          replace_existing,
          existing_run_ids,
          requested_run_id
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp do_start_new_run(
         definition,
         opts,
         service,
         replace_existing,
         existing_run_ids,
         requested_run_id
       ) do
    job_id = definition["job_id"]
    access = requested_job_data_access(definition, opts)

    with :ok <- ensure_service_start_allowed(service, replace_existing, existing_run_ids),
         :ok <- ensure_replacement_run_id(requested_run_id, replace_existing, existing_run_ids),
         :ok <- maybe_ensure_job_data_access(definition, access, service and replace_existing),
         {:ok, %JobBundle{} = bundle} <- load_bundle(definition),
         run_id <- requested_run_id || Runtime.generate_job_id(bundle.manifest.graph_id),
         :ok <- JobData.validate_id(run_id),
         :ok <- ensure_fresh_replacement_run_id(run_id, existing_run_ids, replace_existing),
         :ok <- ensure_run_id_available(run_id),
         {:ok, data_dir} <- JobData.initialize(job_id),
         {:ok, manifest} <-
           prepare_run_manifest(bundle.manifest, definition, run_id, data_dir, access, opts),
         run_bundle <- %JobBundle{bundle | manifest: manifest},
         :ok <- MirrorNeuron.BlueprintValidation.run_input_validation(run_bundle),
         {:ok, definition, replacement} <-
           maybe_replace_service_runs(definition, service and replace_existing),
         {:ok, attached_definition} <- attach_run(definition, run_id),
         result <-
           Runtime.start_job(manifest,
             job_id: run_id,
             job_bundle: run_bundle,
             stable_job_id: job_id,
             run_id: run_id,
             job_data_dir: data_dir,
             job_data_access: access,
             data_generation: definition["data_generation"]
           ) do
      finish_started_run(result, attached_definition, run_id, replacement)
    end
  end

  defp finish_started_run({:ok, run_id, pid}, definition, run_id, replacement) do
    {:ok,
     replacement
     |> Map.merge(%{
       action: if(replacement.replaced_run_ids == [], do: "started", else: "replaced"),
       job_id: definition["job_id"],
       run_id: run_id,
       status: "pending",
       pid: pid
     })}
  end

  defp finish_started_run({:error, reason}, definition, run_id, _replacement) do
    _ = maybe_detach_unpersisted_run(definition, run_id)
    {:error, reason}
  end

  defp finish_started_run(other, _definition, _run_id, _replacement), do: other

  defp maybe_detach_unpersisted_run(definition, run_id) do
    case RedisStore.execution_exists?(run_id) do
      {:ok, true} -> :ok
      _missing -> detach_attached_run(definition, run_id)
    end
  end

  defp detach_attached_run(definition, run_id) do
    remaining = List.delete(Map.get(definition, "run_ids", []), run_id)

    updated =
      definition
      |> Map.put("run_ids", remaining)
      |> Map.put("latest_run_id", List.last(remaining))
      |> increment_revision()

    RedisStore.persist_job_definition(definition["job_id"], updated)
  end

  defp replacement_replay(definition, run_id, true)
       when is_binary(run_id) and run_id != "" do
    existing_run_ids = definition |> Map.get("run_ids", []) |> Enum.uniq()

    if existing_run_ids == [run_id] do
      case RedisStore.fetch_job(run_id) do
        {:ok, run} ->
          {:replay,
           %{
             action: "already_running",
             job_id: definition["job_id"],
             run_id: run_id,
             status: run["status"] || "unknown",
             pid: nil,
             replaced_run_ids: [],
             cleanup_deferred: false,
             cleanup_pending_nodes: []
           }}

        _missing ->
          :continue
      end
    else
      :continue
    end
  end

  defp replacement_replay(_definition, _run_id, _replace_existing), do: :continue

  defp ensure_replacement_scope(true, _replace_existing), do: :ok
  defp ensure_replacement_scope(false, false), do: :ok
  defp ensure_replacement_scope(false, true), do: {:error, :replacement_requires_service_job}

  defp ensure_service_start_allowed(true, false, run_ids) when run_ids != [],
    do: {:error, {:service_run_exists, run_ids}}

  defp ensure_service_start_allowed(_service, _replace_existing, _run_ids), do: :ok

  defp ensure_replacement_run_id(nil, true, _run_ids),
    do: {:error, :replacement_run_id_required}

  defp ensure_replacement_run_id("", true, _run_ids), do: {:error, :replacement_run_id_required}

  defp ensure_replacement_run_id(_run_id, _replace_existing, _run_ids), do: :ok

  defp ensure_fresh_replacement_run_id(run_id, existing_run_ids, true) do
    if run_id in existing_run_ids,
      do: {:error, :replacement_run_id_must_be_fresh},
      else: :ok
  end

  defp ensure_fresh_replacement_run_id(_run_id, _existing_run_ids, false), do: :ok

  defp maybe_ensure_job_data_access(_definition, _access, true), do: :ok

  defp maybe_ensure_job_data_access(definition, access, false),
    do: ensure_job_data_access(definition, access)

  defp maybe_replace_service_runs(definition, true), do: clear_service_runs(definition)
  defp maybe_replace_service_runs(definition, false), do: {:ok, definition, empty_replacement()}

  defp empty_replacement do
    %{
      replaced_run_ids: [],
      cleanup_deferred: false,
      cleanup_pending_nodes: []
    }
  end

  defp load_bundle(definition) do
    fingerprint = get_in(definition, ["bundle_ref", "bundle_fingerprint"])

    case Archive.load(fingerprint) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, _reason} -> JobBundle.load(definition["manifest"])
    end
  end

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
    metadata =
      (manifest.metadata || %{})
      |> stringify()
      |> Map.merge(%{
        "job_id" => definition["job_id"],
        "run_id" => run_id,
        "job_data_access" => access,
        "data_generation" => definition["data_generation"]
      })
      |> maybe_put("schedule_dispatch", Keyword.get(opts, :schedule_metadata))

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
            |> normalize_job_data_access()
          end

        env =
          Map.get(config, "environment", %{})
          |> merge_runtime_configuration(definition, run_id)
          |> Map.merge(Map.put(environment, "MN_JOB_DATA_ACCESS", requested_access))

        %{node | config: Map.put(config, "environment", env)}
      end)

    initial_inputs =
      (manifest.initial_inputs || %{})
      |> deep_merge(stringify(definition["resolved_configuration"] || %{}))
      |> deep_merge(stringify(Keyword.get(opts, :inputs, %{})))
      |> deep_merge(%{
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

  defp merge_runtime_configuration(environment, definition, run_id) do
    case Map.get(environment, "MN_BLUEPRINT_CONFIG_JSON") do
      encoded when is_binary(encoded) ->
        case Jason.decode(encoded) do
          {:ok, config} when is_map(config) ->
            config =
              config
              |> deep_merge(stringify(definition["resolved_configuration"] || %{}))
              |> deep_merge(%{
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

  defp ensure_active(%{"status" => "active"}), do: :ok
  defp ensure_active(_definition), do: {:error, :job_not_active}

  # Mutable file-backed data is node-affine. Transfer/backup may move ownership
  # explicitly later; a scheduler must not silently execute it elsewhere.
  defp ensure_owner_node(%{"owner_node" => owner}) do
    if to_string(NodeAdapter.self()) == owner,
      do: :ok,
      else: {:error, {:job_data_owner_unavailable, owner}}
  end

  defp ensure_no_active_runs(definition) do
    with {:ok, active} <- active_run_records(definition) do
      run_ids = Enum.map(active, & &1["run_id"])
      if run_ids == [], do: :ok, else: {:error, {:active_runs, run_ids}}
    end
  end

  defp prepare_bundle_replacement(definition, bundle, opts) do
    replace_existing = Keyword.get(opts, :replace_existing_run, false)
    target_service = bundle.manifest.type == "service"
    run_ids = definition |> Map.get("run_ids", []) |> Enum.uniq()

    cond do
      replace_existing and not target_service ->
        {:error, :replacement_requires_service_job}

      replace_existing ->
        clear_service_runs(definition)

      target_service and length(run_ids) > 1 ->
        {:error, {:service_run_exists, run_ids}}

      true ->
        with :ok <- ensure_no_active_runs(definition) do
          {:ok, definition, empty_replacement()}
        end
    end
  end

  defp clear_service_runs(definition, run_ids \\ nil) do
    selected = Enum.uniq(run_ids || Map.get(definition, "run_ids", []))

    if selected == [] do
      {:ok, definition, empty_replacement()}
    else
      with {:ok, cleanup} <- cleanup_service_run_ids(selected),
           remaining <- Enum.reject(Map.get(definition, "run_ids", []), &(&1 in selected)),
           updated <-
             definition
             |> Map.put("run_ids", remaining)
             |> Map.put("latest_run_id", List.last(remaining))
             |> Map.put("updated_at", Runtime.timestamp())
             |> increment_revision(),
           {:ok, saved} <- RedisStore.persist_job_definition(definition["job_id"], updated) do
        {:ok, saved,
         %{
           replaced_run_ids: selected,
           cleanup_deferred: cleanup.pending_nodes != [],
           cleanup_pending_nodes: cleanup.pending_nodes
         }}
      end
    end
  end

  defp cleanup_service_run_ids(run_ids) do
    Enum.reduce_while(run_ids, {:ok, %{pending_nodes: []}}, fn run_id, {:ok, cleanup} ->
      case cleanup_run(run_id) do
        {:ok, result} ->
          pending_nodes =
            cleanup.pending_nodes
            |> Kernel.++(Map.get(result, "cleanup_pending_nodes", []))
            |> Kernel.++(Map.get(result, :cleanup_pending_nodes, []))
            |> Enum.uniq()

          {:cont, {:ok, %{pending_nodes: pending_nodes}}}

        {:error, reason} ->
          {:halt, {:error, {:service_run_cleanup_failed, run_id, reason}}}
      end
    end)
  end

  defp cleanup_run(run_id) do
    case RedisStore.fetch_job(run_id) do
      {:ok, %{"status" => status}} when status in @terminal_statuses ->
        Runtime.clear_job_with_result(run_id)

      {:ok, _active} ->
        with {:ok, _status} <- MirrorNeuron.cancel(run_id),
             {:ok, result} <- Runtime.clear_job_with_result(run_id) do
          {:ok, result}
        end

      {:error, reason} ->
        if missing_run?(run_id, reason) do
          with :ok <- Runtime.cleanup_job_resources(run_id, nil),
               :ok <- RedisStore.delete_job(run_id) do
            {:ok, %{}}
          end
        else
          {:error, reason}
        end
    end
  end

  defp do_scheduled_service_transition(definition, opts) do
    opts = Keyword.put_new(opts, :run_id, scheduled_service_run_id(definition, opts))

    with {:ok, records} <- service_run_records(definition) do
      terminal = Enum.filter(records, &service_terminal_record?/1)
      active = Enum.reject(records, &service_terminal_record?/1)

      cond do
        Enum.any?(active, &(&1["status"] == "cancelling")) ->
          {:error, {:service_schedule_blocked, "cancellation in progress"}}

        length(active) > 1 ->
          {:error,
           {:service_schedule_blocked, "multiple active runs require an explicit replacement"}}

        true ->
          with {:ok, definition, cleanup} <-
                 clear_service_runs(definition, Enum.map(terminal, & &1["run_id"])) do
            continue_scheduled_service_transition(definition, List.first(active), cleanup, opts)
          end
      end
    end
  end

  defp continue_scheduled_service_transition(definition, nil, cleanup, opts) do
    with {:ok, started} <- do_start_run_result(definition, opts) do
      action = if cleanup.replaced_run_ids == [], do: "started", else: "replaced"

      {:ok,
       started
       |> Map.put(:action, action)
       |> Map.put(:replaced_run_ids, cleanup.replaced_run_ids)
       |> Map.put(:cleanup_deferred, cleanup.cleanup_deferred)
       |> Map.put(:cleanup_pending_nodes, cleanup.cleanup_pending_nodes)}
    end
  end

  defp continue_scheduled_service_transition(
         definition,
         %{"status" => "paused"} = run,
         cleanup,
         _opts
       ) do
    case MirrorNeuron.resume(run["run_id"]) do
      {:ok, status} ->
        {:ok,
         Map.merge(cleanup, %{
           action: "resumed",
           job_id: definition["job_id"],
           run_id: run["run_id"],
           status: status,
           pid: nil
         })}

      {:error, _reason} = error ->
        error
    end
  end

  defp continue_scheduled_service_transition(
         definition,
         %{"status" => status} = run,
         cleanup,
         _opts
       )
       when status in ["pending", "validated", "scheduled", "running"] do
    {:ok,
     Map.merge(cleanup, %{
       action: "already_running",
       job_id: definition["job_id"],
       run_id: run["run_id"],
       status: run["status"],
       pid: nil
     })}
  end

  defp continue_scheduled_service_transition(_definition, run, _cleanup, _opts),
    do: {:error, {:service_schedule_blocked, "run status #{run["status"]} cannot be resumed"}}

  defp service_run_records(definition) do
    definition
    |> Map.get("run_ids", [])
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, records} ->
      case RedisStore.fetch_job(run_id) do
        {:ok, run} ->
          {:cont, {:ok, [Map.put(run, "run_id", run_id) | records]}}

        {:error, reason} ->
          if missing_run?(run_id, reason) do
            {:cont, {:ok, [%{"run_id" => run_id, "status" => "missing"} | records]}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
    |> then(fn
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end)
  end

  defp service_terminal_record?(%{"status" => status}),
    do: status in @terminal_statuses or status == "missing"

  defp service_definition?(definition) do
    definition["type"] == "service"
  end

  defp scheduled_service_run_id(definition, opts) do
    metadata = Keyword.get(opts, :schedule_metadata, %{})

    digest =
      :crypto.hash(
        :sha256,
        Jason.encode!(%{
          job_id: definition["job_id"],
          schedule_id: metadata["schedule_id"],
          scheduled_for: metadata["scheduled_for"],
          reason: metadata["reason"],
          event_id: get_in(metadata, ["event", "event_id"])
        })
      )
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 24)

    "service_#{digest}"
  end

  defp ensure_job_data_access(definition, requested_access) do
    with {:ok, active} <- active_run_records(definition) do
      conflicting =
        Enum.filter(active, fn run ->
          requested_access == "read_write" or run_job_data_access(run) == "read_write"
        end)

      if conflicting == [] do
        :ok
      else
        {:error, {:job_data_busy, Enum.map(conflicting, & &1["run_id"])}}
      end
    end
  end

  defp active_run_records(definition) do
    definition
    |> Map.get("run_ids", [])
    |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, active} ->
      case RedisStore.execution_exists?(run_id) do
        {:ok, false} ->
          {:cont, {:ok, active}}

        {:ok, true} ->
          case RedisStore.fetch_job(run_id) do
            {:ok, %{"status" => status}} when status in @terminal_statuses ->
              {:cont, {:ok, active}}

            {:ok, run} ->
              {:cont, {:ok, [Map.put(run, "run_id", run_id) | active]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp requested_job_data_access(definition, opts) do
    Keyword.get(opts, :job_data_access, default_job_data_access(definition["storage"]))
    |> normalize_job_data_access()
  end

  defp run_job_data_access(run) do
    run["job_data_access"] ||
      get_in(run, ["manifest", "metadata", "job_data_access"])
      |> normalize_job_data_access()
  end

  defp normalize_job_data_access(access) when access in ["read", "read_only", "ro"], do: "read"
  defp normalize_job_data_access(_access), do: "read_write"

  defp normalize_update(definition, attrs) do
    if Map.has_key?(attrs, "storage") do
      with :ok <- ensure_no_active_runs(definition),
           {:ok, bundle} <- load_bundle(definition),
           {:ok, storage} <- storage_declarations(bundle, attrs["storage"]) do
        {:ok, Map.put(attrs, "storage", storage)}
      end
    else
      {:ok, attrs}
    end
  end

  defp detach_run(nil, _run_id), do: :ok

  defp detach_run(job_id, run_id) do
    with_start_gate(job_id, fn ->
      with {:ok, definition} <- get(job_id) do
        remaining = List.delete(Map.get(definition, "run_ids", []), run_id)

        updated =
          definition
          |> Map.put("run_ids", remaining)
          |> Map.put("latest_run_id", List.last(remaining))

        case RedisStore.persist_job_definition(job_id, updated) do
          {:ok, _definition} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp delete_job_schedules(job_id) do
    with {:ok, schedules} <- RedisStore.list_schedules() do
      schedules
      |> Enum.filter(&(&1["job_id"] == job_id))
      |> Enum.reduce_while(:ok, fn schedule, :ok ->
        case MirrorNeuron.Runtime.ScheduleDispatcher.delete_schedule(schedule["schedule_id"]) do
          :ok -> {:cont, :ok}
          {:ok, _schedule} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp delete_historical_runs(definition) do
    definition
    |> Map.get("run_ids", [])
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn run_id, :ok ->
      case delete_historical_run(run_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:run_cleanup_failed, run_id, reason}}}
      end
    end)
  end

  defp delete_historical_run(run_id) do
    case cleanup_run(run_id) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp missing_run?(run_id, reason),
    do: reason == "job #{run_id} was not found"

  defp pause_job_schedules(job_id) do
    with {:ok, schedules} <- RedisStore.list_schedules() do
      schedules
      |> Enum.filter(&(&1["job_id"] == job_id and &1["status"] != "paused"))
      |> Enum.reduce_while(:ok, fn schedule, :ok ->
        case MirrorNeuron.Runtime.ScheduleDispatcher.pause_schedule(schedule["schedule_id"]) do
          {:ok, _schedule} -> {:cont, :ok}
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp with_start_gate(job_id, callback) do
    with :ok <- JobData.validate_id(job_id) do
      lease_name = "job-data-start:#{job_id}"
      owner_id = "#{NodeAdapter.self()}:#{inspect(self())}:#{System.unique_integer([:positive])}"

      case acquire_start_gate(lease_name, owner_id, @start_gate_retries) do
        {:ok, lease} ->
          try do
            callback.()
          after
            _ = RedisStore.release_fenced_lease(lease_name, owner_id, lease["epoch"])
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp acquire_start_gate(lease_name, owner_id, retries) do
    case RedisStore.acquire_fenced_lease(lease_name, owner_id, @start_gate_ttl_ms) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, {:locked, _lease}} when retries > 0 ->
        Process.sleep(@start_gate_retry_ms)
        acquire_start_gate(lease_name, owner_id, retries - 1)

      {:error, {:locked, _lease}} ->
        {:error, :job_data_start_queue_timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_run(run, job_id, run_id) do
    run
    |> Map.put("job_id", job_id)
    |> Map.put("run_id", run_id)
    |> Map.put_new("attempt_id", "#{run_id}:#{Map.get(run, "attempt", 1)}")
  end

  defp blueprint_id(manifest) do
    get_in(manifest.metadata || %{}, ["blueprint_id"]) || manifest.graph_id
  end

  defp ensure_same_bundle_identity(definition, bundle) do
    current = {definition["graph_id"], definition["blueprint_id"]}
    replacement = {bundle.manifest.graph_id, blueprint_id(bundle.manifest)}

    if current == replacement,
      do: :ok,
      else: {:error, {:job_bundle_identity_mismatch, current, replacement}}
  end

  defp definition_resource_descriptor(definition) do
    metadata = get_in(definition, ["manifest", "metadata"]) || %{}

    %{
      "metadata" =>
        Map.take(metadata, [
          "mn_storage",
          "mn_docker_workers",
          "mn_docker_worker_shared_contexts"
        ])
    }
  end

  defp stable_job_id(graph_id), do: "job_#{JobId.generate(graph_id)}"

  defp storage_declarations(bundle, explicit) do
    metadata = stringify(bundle.manifest.metadata || %{})
    declared = stringify(Map.get(metadata, "job_data", %{}))
    explicit = stringify(explicit || %{})
    storage = if map_size(explicit) == 0, do: declared, else: Map.merge(declared, explicit)
    resources = Map.get(storage, "resources", [])

    if is_list(resources) and Enum.all?(resources, &valid_resource?/1) do
      {:ok, Map.put(storage, "resources", resources)}
    else
      {:error, :invalid_job_data_declarations}
    end
  end

  defp valid_resource?(resource) when is_map(resource) do
    name = Map.get(resource, "name")
    path = Map.get(resource, "path", name)
    access = Map.get(resource, "access", "read_write")

    valid_relative_path?(name) and valid_relative_path?(path) and
      access in ["read", "read_only", "ro", "read_write", "write", "rw"] and
      valid_seed?(Map.get(resource, "seed"))
  end

  defp valid_resource?(_resource), do: false

  defp valid_seed?(nil), do: true
  defp valid_seed?(seed) when is_binary(seed), do: String.starts_with?(seed, "@/")
  defp valid_seed?(_seed), do: false

  defp valid_relative_path?(path) when is_binary(path) do
    Path.type(path) == :relative and path != "" and
      Enum.all?(Path.split(path), &Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, &1))
  end

  defp valid_relative_path?(_path), do: false

  defp seed_paths(bundle, storage) do
    resources = Map.get(stringify(storage || %{}), "resources", [])

    Enum.reduce_while(resources, {:ok, %{}}, fn resource, {:ok, seeds} ->
      case Map.get(resource, "seed") do
        nil ->
          {:cont, {:ok, seeds}}

        "@/" <> relative ->
          with root when is_binary(root) <- bundle.root_path,
               source <- Path.expand(relative, root),
               true <- inside_bundle?(source, root),
               true <- File.dir?(source) do
            target = Map.get(resource, "path", resource["name"])
            {:cont, {:ok, Map.put(seeds, target, source)}}
          else
            _ -> {:halt, {:error, {:invalid_job_data_seed, resource["name"]}}}
          end
      end
    end)
  end

  defp inside_bundle?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp default_job_data_access(storage) do
    storage
    |> stringify()
    |> Map.get("resources", [])
    |> Enum.map(&Map.get(&1, "access", "read_write"))
    |> Enum.all?(&(&1 in ["read", "read_only", "ro"]))
    |> if(do: "read", else: "read_write")
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, child} -> {to_string(key), stringify(child)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, old, new -> deep_merge(old, new) end)
  end

  defp deep_merge(_left, right), do: right

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, stringify(value))
end
