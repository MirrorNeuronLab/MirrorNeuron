defmodule MirrorNeuron.Backup.DurableJob do
  @moduledoc """
  Portable durable-job snapshots. Imported executions remain historical evidence;
  restoring creates a fresh definition with independent storage and run identity.
  """
  alias MirrorNeuron.Backup.Files
  alias MirrorNeuron.Artifacts.{BlobStore, JobStore}
  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.{JobData, JobId}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob

  def export(job_id, send_chunk) do
    StableJob.with_start_gate(job_id, fn ->
      with {:ok, definition} <- StableJob.get(job_id),
           {:ok, runs} <- StableJob.list_runs(job_id),
           :ok <- quiescent(runs),
           {:ok, bundle} <- Archive.load(get_in(definition, ["bundle_ref", "bundle_fingerprint"])),
           {:ok, data_dir} <- JobData.path(job_id) do
        with_temp(fn temp ->
          history =
            Enum.map(runs, fn run ->
              {:ok, events} = RedisStore.read_events(run["run_id"])
              %{"run" => run, "events" => events}
            end)

          schedules =
            Enum.map(definition["schedule_ids"] || [], fn id ->
              {:ok, schedule} = RedisStore.fetch_schedule(id)
              schedule
            end)

          write_json(temp, "history.json", %{"runs" => history, "schedules" => schedules})

          entries =
            Files.tree(bundle.root_path, "bundle") ++
              Files.tree(data_dir, "job-data") ++
              Files.tree(temp, "history") ++
              artifact_entries(runs) ++ blob_entries(definition) ++ staged_entries(definition)

          backup = %{
            "schema_version" => "mn.backup.v3",
            "created_at" => MirrorNeuron.Runtime.timestamp(),
            "definition" => definition,
            "files" => Files.inventory(entries),
            "restore_policy" => "new_job_no_execution_replay"
          }

          write_json(temp, "mn-backup.json", backup)

          Files.chunks(
            entries ++ [{"mn-backup.json", Path.join(temp, "mn-backup.json"), false, 0o600}]
          )
          |> Enum.each(send_chunk)

          :ok
        end)
      end
    end)
  end

  def restore(chunks) do
    with_temp(fn temp ->
      Files.receive!(chunks, temp)
      backup = temp |> Path.join("mn-backup.json") |> File.read!() |> Jason.decode!()

      if backup["schema_version"] != "mn.backup.v3",
        do: raise(ArgumentError, "unsupported backup schema")

      Files.verify!(temp, backup["files"])
      options = temp |> Path.join("restore.json") |> File.read!() |> Jason.decode!()
      definition = backup["definition"]
      if JobData.validate_id(definition["job_id"]) != :ok,
        do: raise(ArgumentError, "invalid source job identity")
      job_id = options["job_id"] || "job_" <> JobId.generate(definition["graph_id"])
      :ok = JobData.validate_id(job_id)
      {:ok, exists} = RedisStore.job_definition_exists?(job_id)
      if exists, do: raise(ArgumentError, "restore job already exists")
      {:ok, data_dir} = JobData.initialize(job_id)

      try do
        copy_contents(Path.join(temp, "job-data"), data_dir)
        evidence_dir = Path.join([data_dir, ".mn-restore", definition["job_id"]])
        File.mkdir_p!(evidence_dir)
        copy_contents(Path.join(temp, "history"), evidence_dir)
        copy_contents(Path.join(temp, "artifacts"), Path.join(evidence_dir, "artifacts"))

        write_json(
          evidence_dir,
          "provenance.json",
          Map.take(backup, ~w(schema_version created_at definition))
        )

        install_blobs(temp)

        case StableJob.create(Path.join(temp, "bundle"),
               job_id: job_id,
               resolved_configuration: options["resolved_configuration"] || %{},
               storage: options["storage"] || %{}
             ) do
          {:ok, created} ->
            {:ok, Map.put(created, "restored_from_job_id", definition["job_id"])}

          {:error, reason} ->
            JobData.delete(job_id)
            {:error, reason}
        end
      rescue
        error ->
          JobData.delete(job_id)
          reraise error, __STACKTRACE__
      end
    end)
  end

  defp quiescent(runs) do
    active = Enum.reject(runs, &(&1["status"] in ["paused", "completed", "failed", "cancelled"]))
    if active == [], do: :ok, else: {:error, {:active_runs, Enum.map(active, & &1["run_id"])}}
  end

  defp artifact_entries(runs) do
    Enum.flat_map(runs, fn run ->
      {:ok, path} = JobStore.job_path(run["run_id"])
      Files.tree(path, "artifacts/" <> run["run_id"])
    end)
  end

  defp blob_entries(definition) do
    refs = get_in(definition, ["manifest", "metadata", "mn_artifacts", "blob_refs"]) || []

    Enum.map(refs, fn ref ->
      sha = ref["sha256"]
      if not BlobStore.valid?(sha), do: raise(ArgumentError, "missing or corrupt payload blob")
      {"blobs/" <> sha, BlobStore.path(sha), false, 0o600}
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp staged_entries(definition) do
    path = get_in(definition, ["manifest", "metadata", "mn_storage", "submission_path"])

    if is_binary(path) do
      root = Path.expand(MirrorNeuron.Artifacts.SharedStorage.root())
      expanded = Path.expand(path)

      if not String.starts_with?(expanded, root <> "/"),
        do: raise(ArgumentError, "job staging must be inside runtime shared storage")

      if not File.dir?(expanded), do: raise(ArgumentError, "job staging files are missing")
      Files.tree(expanded, "staging")
    else
      []
    end
  end

  defp install_blobs(temp) do
    dir = Path.join(temp, "blobs")

    if File.dir?(dir) do
      Enum.each(File.ls!(dir), fn sha ->
        {:ok, _} = BlobStore.put_file(Path.join(dir, sha), sha)
      end)
    end
  end

  defp copy_contents(source, destination) do
    if File.dir?(source) do
      File.mkdir_p!(destination)

      Enum.each(File.ls!(source), fn name ->
        {:ok, _} = File.cp_r(Path.join(source, name), Path.join(destination, name))
      end)
    end
  end

  defp write_json(root, name, value), do: File.write!(Path.join(root, name), Jason.encode!(value))

  defp with_temp(callback) do
    temp =
      Path.join(
        System.tmp_dir!(),
        "mn-job-backup-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(temp)
    File.chmod!(temp, 0o700)

    try do
      callback.(temp)
    after
      File.rm_rf(temp)
    end
  end
end
