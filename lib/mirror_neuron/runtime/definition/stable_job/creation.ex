defmodule MirrorNeuron.Runtime.StableJob.Creation do
  @moduledoc "Loads definitions, initializes persistent data and validates relocation replacement."

  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.JobData
  alias MirrorNeuron.JobId
  alias MirrorNeuron.Runtime.JobResponse
  alias MirrorNeuron.Runtime.StableJob.Lifecycle
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Runtime.StableJob.Queries
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.StableJob.StartGate
  alias MirrorNeuron.Runtime.StableJob.Storage
  alias MirrorNeuron.Runtime.StableJob.Values

  def create(input, opts \\ []) do
    with {:ok, bundle} <- JobBundle.load(input),
         job_id <- Keyword.get(opts, :job_id) || stable_job_id(bundle.manifest.graph_id),
         :ok <- JobData.validate_id(job_id) do
      StartGate.with_start_gate(job_id, fn -> create_loaded(bundle, job_id, opts) end)
    end
  end

  defp create_loaded(bundle, job_id, opts) do
    with {:ok, previous} <- restore_predecessor(job_id, opts),
         {:ok, storage} <- Storage.storage_declarations(bundle, Keyword.get(opts, :storage, %{})),
         {:ok, seed_paths} <- Storage.seed_paths(bundle, storage),
         {:ok, data_dir} <- initialize_data(job_id, seed_paths, opts, previous) do
      now = Runtime.timestamp()

      definition = %{
        "job_id" => job_id,
        "blueprint_id" => Lifecycle.blueprint_id(bundle.manifest),
        "graph_id" => bundle.manifest.graph_id,
        "job_name" => bundle.manifest.job_name,
        "type" => bundle.manifest.type,
        "manifest" => Manifest.to_map(bundle.manifest),
        "bundle_ref" => Runtime.bundle_ref(bundle.manifest, bundle),
        "resolved_configuration" =>
          Values.stringify(Keyword.get(opts, :resolved_configuration, %{})),
        "schedules" => Values.stringify(Keyword.get(opts, :schedules, [])),
        "schedule_ids" => [],
        "storage" => storage,
        "owner_node" => to_string(Keyword.get(opts, :owner_node, NodeAdapter.self())),
        "status" =>
          if(Keyword.has_key?(opts, :relocation), do: "relocation_staged", else: "active"),
        "revision" => if(previous, do: previous["revision"] + 1, else: 1),
        "data_generation" =>
          if(previous,
            do:
              max(
                previous["data_generation"] || 1,
                get_in(Keyword.get(opts, :relocation, %{}), ["source_data_generation"]) || 1
              ) + 1,
            else: get_in(Keyword.get(opts, :relocation, %{}), ["source_data_generation"]) || 1
          ),
        "data_dir" => data_dir,
        "run_ids" => [],
        "created_at" => Keyword.get(opts, :created_at) || now,
        "updated_at" => now
      }

      definition =
        if Keyword.has_key?(opts, :relocation),
          do: Map.put(definition, "relocation", Keyword.fetch!(opts, :relocation)),
          else: definition

      persisted =
        if previous,
          do: RedisStore.compare_job_definition(job_id, previous["revision"], definition),
          else: RedisStore.create_job_definition(job_id, definition)

      case persisted do
        {:ok, saved} = result ->
          _ = JobResponse.definition_changed(saved)
          result

        error ->
          error
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_predecessor(job_id, opts) do
    with {:ok, exists} <- RedisStore.job_definition_exists?(job_id) do
      if exists do
        with {:ok, previous} <- Queries.get(job_id),
             journal when is_map(journal) <- Keyword.get(opts, :relocation),
             true <- journal["replaces_revision"] == previous["revision"],
             true <-
               MirrorNeuron.Runtime.JobRelocation.replaceable_destination?(previous, journal) do
          {:ok, path} = JobData.path(job_id)
          identity = File.read(Path.join(path, ".mn-restore-identity"))

          if match?({:ok, _}, identity) or identity == {:error, :enoent},
            do: {:ok, Map.put(previous, :restore_data_identity, identity)},
            else: identity
        else
          _ -> {:error, :job_already_exists}
        end
      else
        {:ok, nil}
      end
    end
  end

  defp initialize_data(job_id, seed_paths, opts, previous) do
    case Keyword.get(opts, :restored_data_dir) do
      nil ->
        JobData.initialize(job_id, seed_paths)

      staging ->
        replacement =
          if previous do
            [replace_identity: previous[:restore_data_identity]]
          else
            []
          end

        JobData.install_restore(
          job_id,
          staging,
          Keyword.fetch!(opts, :restore_identity),
          replacement
        )
    end
  end

  defp stable_job_id(graph_id), do: "job_#{JobId.generate(graph_id)}"
end
