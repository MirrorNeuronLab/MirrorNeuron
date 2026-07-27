defmodule MirrorNeuron.JobBackup do
  @moduledoc false

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.{Config, JobBundle, JobId, Manifest}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  @schema_version "mn.backup.v2"
  @restore_pause_reason "job was restored from a backup and must remain paused"
  @stale_runtime_fields [
    "lease",
    "lease_epoch",
    "lease_owner",
    "pid",
    "owner_pid",
    "assigned_node",
    "node_owner",
    "service_registrations",
    "active_services"
  ]

  @resumable_runtime_fields [
    "workflow_state",
    "workflow_state_ref",
    "pending_workflow_completion",
    "policy_state"
  ]

  def export_job(job_id) when is_binary(job_id) and job_id != "" do
    with {:ok, job} <- RedisStore.fetch_job(job_id),
         :ok <- ensure_paused(job),
         {:ok, events} <- RedisStore.read_events(job_id),
         {:ok, bundle_files} <- export_bundle_files(job) do
      job = Map.drop(job, @resumable_runtime_fields)

      backup = %{
        "schema_version" => @schema_version,
        "created_at" => Runtime.timestamp(),
        "source" => source_metadata(job),
        "target_policy" => %{
          "restore_mode" => "clone",
          "status_after_restore" => "paused",
          "job_id" => "generate_new",
          "run_id" => "generate_new"
        },
        "sections" => %{
          "runtime/job.json" => true,
          "runtime/events.jsonl" => true,
          "bundle/manifest.json" => Map.has_key?(bundle_files, "manifest.json"),
          "bundle/payloads" => true,
          "run_store" => "optional",
          "knowledge" => "optional"
        },
        "runtime" => %{
          "job" => job,
          "events" => events
        },
        "bundle" => %{
          "file_count" => map_size(bundle_files),
          "files" => Enum.sort(Map.keys(bundle_files))
        }
      }

      {:ok, backup, bundle_files}
    end
  end

  def export_job(_job_id), do: {:error, "job_id is required"}

  def restore_job(backup, bundle_files, opts \\ [])

  def restore_job(backup, bundle_files, opts) when is_map(backup) and is_map(bundle_files) do
    with :ok <- validate_schema(backup),
         {:ok, runtime} <- runtime_section(backup),
         {:ok, old_job} <- runtime_job(runtime),
         {:ok, old_job_id} <- source_job_id(backup, old_job),
         {:ok, target_blueprint_id} <- target_blueprint_id(backup, old_job, opts),
         {:ok, run_id} <- target_run_id(backup, opts),
         new_job_id <- JobId.generate(target_blueprint_id),
         {:ok, bundle} <- restore_bundle(new_job_id, bundle_files, target_blueprint_id, run_id),
         manifest_map <- Manifest.to_map(bundle.manifest),
         manifest_ref <- Runtime.bundle_ref(bundle.manifest, bundle),
         provenance <-
           provenance(backup, old_job, old_job_id, new_job_id, target_blueprint_id, run_id),
         {:ok, restored_job} <-
           persist_restored_runtime(
             runtime,
             old_job_id,
             new_job_id,
             run_id,
             bundle.manifest,
             manifest_map,
             manifest_ref,
             provenance
           ),
         {:ok, recovery_result} <- start_paused_recovery(new_job_id) do
      {:ok,
       %{
         "job_id" => new_job_id,
         "run_id" => run_id,
         "blueprint_id" => target_blueprint_id,
         "status" => restored_job["status"],
         "source_job_id" => old_job_id,
         "source_run_id" => get_in(provenance, ["source", "run_id"]),
         "restore_provenance" => provenance,
         "recovery" => recovery_result
       }}
    end
  end

  def restore_job(_backup, _bundle_files, _opts), do: {:error, "invalid backup payload"}

  def schema_version, do: @schema_version

  defp ensure_paused(%{"status" => "paused"}), do: :ok

  defp ensure_paused(%{"job_id" => job_id, "status" => status}) do
    {:error,
     "job #{job_id} must be paused before backup; current status is #{status || "unknown"}"}
  end

  defp ensure_paused(_job), do: {:error, "job must be paused before backup"}

  defp validate_schema(%{"schema_version" => @schema_version}), do: :ok

  defp validate_schema(%{"schema_version" => other}),
    do: {:error, "unsupported backup schema #{inspect(other)}"}

  defp validate_schema(_backup), do: {:error, "backup is missing schema_version"}

  defp runtime_section(%{"runtime" => runtime}) when is_map(runtime), do: {:ok, runtime}
  defp runtime_section(_backup), do: {:error, "backup is missing runtime state"}

  defp runtime_job(%{"job" => job}) when is_map(job), do: {:ok, job}
  defp runtime_job(_runtime), do: {:error, "backup is missing runtime/job.json"}

  defp source_job_id(backup, job) do
    value =
      get_in(backup, ["source", "job_id"]) ||
        job["job_id"]

    case non_empty_string(value) do
      nil -> {:error, "backup is missing source job_id"}
      job_id -> {:ok, job_id}
    end
  end

  defp target_blueprint_id(backup, job, opts) do
    value =
      opts[:blueprint_id] ||
        get_in(backup, ["source", "blueprint_id"]) ||
        get_in(job, ["manifest", "metadata", "mn_cli", "blueprint_id"]) ||
        job["graph_id"] ||
        get_in(job, ["manifest", "graph_id"])

    case non_empty_string(value) do
      nil -> {:error, "restore requires a target blueprint_id"}
      blueprint_id -> {:ok, blueprint_id}
    end
  end

  defp target_run_id(_backup, opts) do
    value = opts[:run_id]

    case non_empty_string(value) do
      nil -> {:ok, "restore-#{System.unique_integer([:positive])}"}
      run_id -> {:ok, run_id}
    end
  end

  defp export_bundle_files(job) do
    case load_export_bundle(job) do
      {:ok, %JobBundle{root_path: root_path}} when is_binary(root_path) ->
        collect_bundle_files(root_path)

      {:ok, %JobBundle{manifest: manifest}} ->
        {:ok, %{"manifest.json" => Jason.encode!(Manifest.to_map(manifest), pretty: true)}}

      {:error, _reason} ->
        export_embedded_manifest(job)
    end
  end

  defp load_export_bundle(job) do
    manifest_ref = job["manifest_ref"] || %{}
    fingerprint = manifest_ref["bundle_fingerprint"] || manifest_ref[:bundle_fingerprint]
    job_path = manifest_ref["job_path"] || manifest_ref[:job_path]

    cond do
      is_binary(fingerprint) and fingerprint != "" ->
        case Archive.load(fingerprint) do
          {:ok, bundle} -> {:ok, bundle}
          {:error, _reason} when is_binary(job_path) -> JobBundle.load_filesystem_path(job_path)
          {:error, reason} -> {:error, reason}
        end

      is_binary(job_path) and job_path != "" ->
        JobBundle.load_filesystem_path(job_path)

      is_map(job["manifest"]) ->
        case workflow_manifest_incomplete?(job["manifest"]) do
          true -> {:error, :incomplete_embedded_workflow_manifest}
          false -> JobBundle.load(job["manifest"])
        end

      true ->
        {:error, :missing_bundle}
    end
  end

  defp collect_bundle_files(root_path) do
    with {:ok, paths} <- regular_files(root_path) do
      files =
        paths
        |> Enum.map(fn path ->
          relative_path = Path.relative_to(path, root_path)
          {relative_path, File.read!(path)}
        end)
        |> Map.new()

      cond do
        not Map.has_key?(files, "manifest.json") ->
          {:error, "backup bundle is missing manifest.json"}

        true ->
          {:ok, files}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp regular_files(root_path) do
    root = Path.expand(root_path)

    files =
      root
      |> walk_files()
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

    {:ok, files}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp walk_files(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.flat_map(&walk_files(Path.join(path, &1)))

      true ->
        []
    end
  end

  defp export_embedded_manifest(%{"manifest" => manifest}) when is_map(manifest) do
    if workflow_manifest_incomplete?(manifest) do
      {:error, "embedded mn.workflow/v1 manifest is missing contract, flow, or runtime"}
    else
      {:ok, %{"manifest.json" => Jason.encode!(manifest, pretty: true)}}
    end
  end

  defp export_embedded_manifest(_job), do: {:error, "backup bundle is unavailable"}

  defp workflow_manifest_incomplete?(%{"apiVersion" => "mn.workflow/v1"} = manifest) do
    not (is_map(manifest["contract"]) and is_map(manifest["flow"]) and is_map(manifest["runtime"]))
  end

  defp workflow_manifest_incomplete?(_manifest), do: false

  defp restore_bundle(new_job_id, bundle_files, blueprint_id, run_id) do
    root =
      Path.join([
        Config.string("MN_TEMP_DIR", :temp_dir),
        "restored_bundles",
        new_job_id
      ])

    with :ok <- prepare_bundle_root(root),
         :ok <- write_bundle_files(root, bundle_files),
         :ok <- annotate_manifest_file(root, blueprint_id, run_id),
         {:ok, bundle} <- JobBundle.load_filesystem_path(root) do
      {:ok, bundle}
    end
  end

  defp prepare_bundle_root(root) do
    if File.exists?(root) do
      {:error, "restore bundle cache already exists for generated job id"}
    else
      File.mkdir_p!(Path.join(root, "payloads"))
      :ok
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp write_bundle_files(root, bundle_files) do
    Enum.reduce_while(bundle_files, :ok, fn {relative_path, contents}, :ok ->
      case safe_relative_path(relative_path) do
        {:ok, safe_path} ->
          full_path = Path.join(root, safe_path)
          File.mkdir_p!(Path.dirname(full_path))
          File.write!(full_path, contents)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp annotate_manifest_file(root, blueprint_id, run_id) do
    manifest_path = Path.join(root, "manifest.json")

    with {:ok, contents} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(contents),
         manifest <- annotate_manifest(manifest, blueprint_id, run_id),
         :ok <- File.write(manifest_path, Jason.encode!(manifest, pretty: true)) do
      :ok
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "bundle manifest.json is invalid JSON: #{Exception.message(error)}"}

      {:error, :enoent} ->
        {:error, "bundle is missing manifest.json"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp annotate_manifest(manifest, blueprint_id, run_id) when is_map(manifest) do
    metadata = Map.get(manifest, "metadata", %{})
    metadata = if is_map(metadata), do: metadata, else: %{}
    mn_cli = Map.get(metadata, "mn_cli", %{})
    mn_cli = if is_map(mn_cli), do: mn_cli, else: %{}

    metadata =
      Map.put(
        metadata,
        "mn_cli",
        Map.merge(mn_cli, %{
          "blueprint_id" => blueprint_id,
          "blueprint_run_id" => run_id
        })
      )

    Map.put(manifest, "metadata", metadata)
  end

  defp annotate_manifest(_manifest, _blueprint_id, _run_id), do: %{}

  defp persist_restored_runtime(
         runtime,
         old_job_id,
         new_job_id,
         run_id,
         manifest,
         manifest_map,
         manifest_ref,
         provenance
       ) do
    events = Map.get(runtime, "events", [])

    restored_job =
      runtime["job"]
      |> rewrite_ids(old_job_id, new_job_id, source_run_id(provenance), run_id)
      |> Map.drop(@stale_runtime_fields)
      |> Map.drop(@resumable_runtime_fields)
      |> Map.put("job_id", new_job_id)
      |> Map.put("graph_id", manifest.graph_id)
      |> Map.put("job_name", manifest.job_name)
      |> Map.put("status", "paused")
      |> Map.put("manifest", manifest_map)
      |> Map.put("manifest_ref", manifest_ref)
      |> Map.put("topology", Manifest.topology(manifest))
      |> Map.put("root_agent_ids", manifest.entrypoints)
      |> Map.put("submitted_at", Runtime.timestamp())
      |> Map.put("updated_at", Runtime.timestamp())
      |> Map.put("restore_provenance", provenance)
      |> Map.put("recovery", %{
        "status" => "restored_from_backup",
        "reason" => @restore_pause_reason,
        "requires_review" => true,
        "can_resume" => true,
        "updated_at" => Runtime.timestamp()
      })
      |> Map.put("recovery_status", "restored_from_backup")
      |> Map.put("recovery_reason", @restore_pause_reason)
      |> Map.put("recovery_requires_review", true)

    with {:ok, _job} <- RedisStore.persist_job(new_job_id, restored_job),
         {:ok, _events} <-
           persist_restored_events(events, old_job_id, new_job_id, run_id, provenance) do
      {:ok, restored_job}
    end
  end

  defp persist_restored_events(events, old_job_id, new_job_id, run_id, provenance)
       when is_list(events) do
    restored =
      events
      |> Enum.map(&rewrite_ids(&1, old_job_id, new_job_id, source_run_id(provenance), run_id))
      |> Kernel.++([
        %{
          "type" => "job_restored_from_backup",
          "source_job_id" => old_job_id,
          "new_job_id" => new_job_id,
          "run_id" => run_id,
          "timestamp" => Runtime.timestamp()
        }
      ])

    RedisStore.replace_job_events(new_job_id, restored)
  end

  defp persist_restored_events(_events, _old_job_id, _new_job_id, _run_id, _provenance),
    do: {:error, "runtime/events.jsonl must contain events"}

  defp start_paused_recovery(new_job_id) do
    {:ok,
     %{
       job_id: new_job_id,
       action: :paused_for_review,
       reason: @restore_pause_reason
     }}
  end

  defp provenance(backup, old_job, old_job_id, new_job_id, blueprint_id, run_id) do
    source = Map.get(backup, "source", %{})

    %{
      "schema_version" => @schema_version,
      "restored_at" => Runtime.timestamp(),
      "source" => %{
        "job_id" => old_job_id,
        "run_id" =>
          source["run_id"] ||
            get_in(old_job, ["manifest", "metadata", "mn_cli", "blueprint_run_id"]),
        "blueprint_id" =>
          source["blueprint_id"] ||
            get_in(old_job, ["manifest", "metadata", "mn_cli", "blueprint_id"]),
        "graph_id" =>
          source["graph_id"] || old_job["graph_id"] || get_in(old_job, ["manifest", "graph_id"]),
        "created_at" => backup["created_at"]
      },
      "target" => %{
        "job_id" => new_job_id,
        "run_id" => run_id,
        "blueprint_id" => blueprint_id
      }
    }
  end

  defp source_metadata(job) do
    mn_cli = get_in(job, ["manifest", "metadata", "mn_cli"]) || %{}

    %{
      "job_id" => job["job_id"],
      "run_id" => mn_cli["blueprint_run_id"],
      "blueprint_id" => mn_cli["blueprint_id"],
      "graph_id" => job["graph_id"] || get_in(job, ["manifest", "graph_id"]),
      "submitted_at" => job["submitted_at"],
      "status" => job["status"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp source_run_id(%{"source" => %{"run_id" => run_id}}), do: run_id
  defp source_run_id(_provenance), do: nil

  defp rewrite_ids(value, old_job_id, new_job_id, old_run_id, new_run_id) do
    replacements =
      [{old_job_id, new_job_id}, {old_run_id, new_run_id}]
      |> Enum.filter(fn {old, new} ->
        is_binary(old) and old != "" and is_binary(new) and new != "" and old != new
      end)

    rewrite_exact(value, replacements)
  end

  defp rewrite_exact(value, replacements) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} ->
      {rewrite_exact(key, replacements), rewrite_exact(nested, replacements)}
    end)
    |> Map.new()
  end

  defp rewrite_exact(value, replacements) when is_list(value) do
    Enum.map(value, &rewrite_exact(&1, replacements))
  end

  defp rewrite_exact(value, replacements) when is_binary(value) do
    case Enum.find(replacements, fn {old, _new} -> value == old end) do
      {_old, new} -> new
      nil -> value
    end
  end

  defp rewrite_exact(value, _replacements), do: value

  defp safe_relative_path(path) when is_binary(path) do
    cond do
      path in ["", "."] ->
        {:error, "bundle file path must not be empty"}

      Path.type(path) != :relative ->
        {:error, "bundle file path must be relative: #{inspect(path)}"}

      ".." in Path.split(path) ->
        {:error, "bundle file path must stay inside the bundle: #{inspect(path)}"}

      String.contains?(path, "\\") ->
        {:error, "bundle file path must use forward slashes: #{inspect(path)}"}

      true ->
        {:ok, path}
    end
  end

  defp safe_relative_path(path),
    do: {:error, "bundle file path must be a string: #{inspect(path)}"}

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> non_empty_string()

  defp non_empty_string(value) when is_integer(value), do: Integer.to_string(value)
  defp non_empty_string(_value), do: nil
end
