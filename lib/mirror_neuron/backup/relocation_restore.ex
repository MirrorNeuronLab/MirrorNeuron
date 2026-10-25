defmodule MirrorNeuron.Backup.RelocationRestore do
  @moduledoc false
  alias MirrorNeuron.Artifacts.{JobStore, SharedStorage}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob

  def finalize(%{"status" => "relocation_staged"} = definition) do
    root =
      Path.join([
        definition["data_dir"],
        ".mn-restore",
        definition["job_id"],
        definition["relocation"]["transfer_id"]
      ])

    history = root |> Path.join("history.json") |> File.read!() |> Jason.decode!()
    ids = Enum.map(history["runs"] || [], &restore_run!(&1, definition, root))
    retire_schedules!(definition)
    schedule_ids = Enum.map(history["schedules"] || [], &restore_schedule!(&1, definition))

    updated =
      definition
      |> Map.put("historical_run_ids", ids)
      |> Map.put("schedule_ids", schedule_ids)
      |> Map.update!("relocation", &Map.put(&1, "phase", "staged"))
      |> Map.update!("revision", &(&1 + 1))

    case RedisStore.compare_job_definition(definition["job_id"], definition["revision"], updated) do
      {:error, :revision_mismatch} ->
        with {:ok, current} <- StableJob.get(definition["job_id"]),
             true <- current["status"] in ["relocation_staged", "active"],
             true <-
               current["relocation"]["transfer_id"] == definition["relocation"]["transfer_id"],
             true <- current["relocation"]["phase"] in ["staged", "active"] do
          {:ok, current}
        else
          _ -> {:error, :invalid_relocation_state}
        end

      result ->
        result
    end
  end

  defp restore_run!(item, definition, root) do
    run = item["run"]
    id = run["run_id"] || run["job_id"]

    if MirrorNeuron.JobData.validate_id(id) != :ok or
         run["status"] not in ~w(completed failed cancelled),
       do: raise(ArgumentError, "relocation history must contain terminal runs")

    missing = "job #{id} was not found"

    case RedisStore.fetch_job(id) do
      {:ok, existing} ->
        if existing["stable_job_id"] != definition["job_id"] or
             existing["status"] not in ~w(completed failed cancelled),
           do: raise(ArgumentError, "relocation history conflicts with an existing run")

        id

      {:error, ^missing} ->
        restore_new_run!(item, definition, root, run, id)

      _ ->
        raise ArgumentError, "could not verify historical run identity"
    end
  end

  defp restore_new_run!(item, definition, root, run, id) do
    {:ok, artifacts} = JobStore.ensure_job_dir(id)
    copy_contents!(Path.join([root, "artifacts", id]), artifacts)
    submission = "relocated-" <> definition["relocation"]["transfer_id"] <> "-" <> id
    staging = Path.join([SharedStorage.root(), "submissions", submission])
    copy_contents!(Path.join([root, "staging", id]), staging)
    manifest = run["manifest"] || %{}
    metadata = manifest["metadata"] || %{}
    storage = metadata["mn_storage"] || %{}
    old_path = storage["submission_path"]
    manifest = rebase(manifest, old_path, staging)

    metadata =
      Map.put(
        manifest["metadata"] || %{},
        "mn_storage",
        storage
        |> rebase(old_path, staging)
        |> Map.put("submission_id", submission)
        |> Map.put("submission_path", staging)
        |> Map.delete("host_submission_path")
      )

    run =
      run
      |> Map.put("manifest", Map.put(manifest, "metadata", metadata))
      |> Map.put("job_id", id)
      |> Map.put("run_id", id)
      |> Map.put("owner_node", definition["owner_node"])
      |> Map.put("restored_evidence", true)
      |> Map.delete("admission")

    {:ok, _} = RedisStore.persist_job(id, run)
    {:ok, _} = RedisStore.replace_job_events(id, item["events"] || [])
    id
  end

  defp retire_schedules!(definition) do
    job_id = definition["job_id"]

    Enum.each(definition["relocation"]["retired_schedule_ids"] || [], fn id ->
      case RedisStore.fetch_schedule(id) do
        {:ok, %{"job_id" => job, "enabled" => false}} when job == job_id ->
          :ok = RedisStore.delete_schedule(id)

        {:ok, _} ->
          raise ArgumentError, "retired schedule ownership changed"

        {:error, reason} ->
          if reason != "schedule #{id} was not found",
            do: raise(ArgumentError, "could not retire paused schedule")
      end
    end)
  end

  defp restore_schedule!(schedule, definition) do
    # Original schedules were paused before freezing. Keep them paused and
    # preserve timing/occurrence semantics without replaying an old dispatch.
    id =
      "relocated_" <>
        definition["relocation"]["transfer_id"] <>
        "_" <>
        Base.encode16(:crypto.hash(:sha256, schedule["schedule_id"]), case: :lower)

    record =
      schedule
      |> Map.merge(%{
        "schedule_id" => id,
        "job_id" => definition["job_id"],
        "owner_node" => definition["owner_node"],
        "enabled" => false,
        "status" => "paused",
        "manifest" => definition["manifest"],
        "bundle_ref" => definition["bundle_ref"],
        "authority_epoch" => MirrorNeuron.Runtime.NodeAdmission.authority_epoch(),
        "active_run_ids" => []
      })

    {:ok, _} = RedisStore.persist_schedule(id, record)
    id
  end

  defp copy_contents!(source, destination) do
    if File.dir?(source) do
      File.mkdir_p!(destination)

      Enum.each(File.ls!(source), fn name ->
        {:ok, _} = File.cp_r(Path.join(source, name), Path.join(destination, name))
      end)
    end
  end

  defp rebase(value, old, new) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, rebase(item, old, new)} end)

  defp rebase(value, old, new) when is_list(value), do: Enum.map(value, &rebase(&1, old, new))

  defp rebase(value, old, new) when is_binary(value) and is_binary(old) and old != "",
    do: String.replace(value, old, new)

  defp rebase(value, _, _), do: value
end
