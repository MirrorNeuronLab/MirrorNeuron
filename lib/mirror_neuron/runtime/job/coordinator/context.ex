defmodule MirrorNeuron.Runtime.JobCoordinator.Context do
  @moduledoc "Immutable definition cache and compact per-worker runtime context."

  alias MirrorNeuron.Execution.Profile
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Backpressure
  alias MirrorNeuron.Runtime.JobCoordinator.Topology
  alias MirrorNeuron.Runtime.WorkflowLedger
  alias MirrorNeuron.Scheduler

  def cache_definition(state) do
    manifest = MirrorNeuron.Manifest.to_map(state.manifest)

    Map.put(state, :definition, %{
      manifest: manifest,
      artifact_refs: MirrorNeuron.Artifacts.BlobRef.collect(manifest),
      checkpoint_identity:
        MirrorNeuron.Runtime.RunRetry.definition_identity(
          manifest,
          state.manifest.initial_inputs || %{}
        ),
      bundle_paths: runtime_bundle_paths(state)
    })
  end

  def agent_runtime_context(state, node) do
    lease = Keyword.get(state.opts, :job_lease)
    paths = state.definition.bundle_paths
    targets = Map.get(state.outbound_edges_by_node, node.node_id, []) |> Enum.map(& &1.to_node)
    neighbors = Enum.uniq([node.node_id | targets])

    %{
      attempt: state.attempt,
      bundle_root: paths.bundle_root,
      manifest_path: paths.manifest_path,
      payloads_path: paths.payloads_path,
      artifact_refs: state.definition.artifact_refs,
      manifest_ref: manifest_ref(state),
      allocation: Scheduler.allocation(Topology.scheduler_plan(state), node.node_id),
      runtime_env: runtime_environment(state),
      delivery_version: state.delivery_version,
      lease_epoch: lease && lease["epoch"],
      lease_owner: lease && lease["owner_id"],
      workflow_run_id: WorkflowLedger.run_id(state.workflow_state),
      workflow_agent_steps:
        Map.take(WorkflowLedger.agent_to_step(state.workflow_state), neighbors),
      backpressure_by_agent:
        Map.new(targets, fn id ->
          {id, state.nodes_by_id |> Map.fetch!(id) |> Backpressure.config() |> Map.to_list()}
        end),
      execution_profiles: %{node.node_id => Profile.profile_name(node.config)}
    }
  end

  def runtime_environment(state) do
    run_id = Keyword.get(state.opts, :run_id, state.job_id)

    MirrorNeuron.Runtime.RedisEnvironment.agent_env()
    |> Map.merge(%{
      "MN_JOB_ID" => Keyword.get(state.opts, :stable_job_id) || state.job_id,
      "MN_RUN_ID" => run_id,
      "MN_CONTROL_GENERATION" => state.lifecycle["generation"],
      "MN_ATTEMPT_ID" => "#{run_id}:#{state.attempt}",
      "MN_JOB_DATA_DIR" => Keyword.get(state.opts, :job_data_dir),
      "MN_JOB_DATA_ACCESS" => Keyword.get(state.opts, :job_data_access),
      "MN_JOB_DATA_GENERATION" => to_string(Keyword.get(state.opts, :data_generation, 1))
    })
    |> Map.merge(retry_environment(state))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp retry_environment(state) do
    case Keyword.get(state.opts, :checkpoint_retry) do
      %{job: job, request: request} ->
        current =
          case RedisStore.fetch_job(state.job_id) do
            {:ok, record} -> record
            _ -> job
          end

        clock = current["running_time"] || %{}

        %{
          "MN_RUN_RETRY_JSON" =>
            Jason.encode!(%{
              "configuration_overrides" => request["effective_configuration_overrides"] || %{},
              "consumed_seconds" => (clock["accumulated_ms"] || 0) / 1000,
              "active_since" => clock["active_since"] || Runtime.timestamp(),
              "attempt" => state.attempt
            })
        }

      _ ->
        %{}
    end
  end

  def manifest_ref(state) do
    Keyword.get(state.opts, :bundle_ref) ||
      Runtime.bundle_ref(state.manifest, state.bundle)
  end

  def runtime_bundle_root(state), do: state.definition.bundle_paths.bundle_root

  defp runtime_bundle_paths(state) do
    case bundle_cache_path(manifest_ref(state)) do
      nil ->
        %{
          bundle_root: state.bundle && state.bundle.root_path,
          manifest_path: state.bundle && state.bundle.manifest_path,
          payloads_path: state.bundle && state.bundle.payloads_path
        }

      cache_path ->
        %{
          bundle_root: cache_path,
          manifest_path: Path.join(cache_path, "manifest.json"),
          payloads_path: Path.join(cache_path, "payloads")
        }
    end
  end

  defp bundle_cache_path(manifest_ref) when is_map(manifest_ref) do
    storage = Map.get(manifest_ref, "bundle_storage") || Map.get(manifest_ref, :bundle_storage)
    cache_path = Map.get(manifest_ref, "cache_path") || Map.get(manifest_ref, :cache_path)

    if storage in ["redis", "local_cache", "shared_fs", "shared_fs_cas"] and
         is_binary(cache_path) and cache_path != "" do
      case JobBundle.load_filesystem_path(cache_path) do
        {:ok, _bundle} -> cache_path
        {:error, _reason} -> nil
      end
    end
  end

  defp bundle_cache_path(_manifest_ref), do: nil
end
