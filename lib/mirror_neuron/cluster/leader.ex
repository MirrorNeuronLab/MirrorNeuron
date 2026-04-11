defmodule MirrorNeuron.Cluster.Leader do
  use GenServer
  require Logger

  alias MirrorNeuron.Persistence.RedisStore

  @lease_duration_ms 10_000
  @refresh_interval_ms 3_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    state = %{
      is_leader: false,
      node_name: to_string(Node.self())
    }

    Process.send_after(self(), :campaign, 500)
    {:ok, state}
  end

  @impl true
  def handle_info(:campaign, state) do
    current_node = to_string(Node.self())

    # If the node name changed (e.g. CLI fully initialized)
    state =
      if current_node != state.node_name do
        if state.is_leader do
          RedisStore.release_lease("cluster:leader", state.node_name)
        end

        %{state | is_leader: false, node_name: current_node}
      else
        state
      end

    new_state =
      if state.is_leader do
        case RedisStore.renew_lease("cluster:leader", state.node_name, @lease_duration_ms) do
          :ok ->
            # Keep leadership
            state

          {:error, _} ->
            # Failed to renew (e.g. expired and someone else took it)
            handle_lost_leadership(state)
        end
      else
        case RedisStore.acquire_lease("cluster:leader", state.node_name, @lease_duration_ms) do
          :ok ->
            handle_became_leader(state)

          {:error, :locked} ->
            state

          {:error, reason} ->
            Logger.warning("Redis error during leader campaign: #{inspect(reason)}")
            state
        end
      end

    Process.send_after(self(), :campaign, @refresh_interval_ms)
    {:noreply, new_state}
  end

  defp handle_became_leader(state) do
    if not state.is_leader do
      Logger.notice("Node #{state.node_name} became cluster leader")
    end

    sweep_orphaned_jobs()
    %{state | is_leader: true}
  end

  defp handle_lost_leadership(state) do
    if state.is_leader do
      Logger.notice("Node #{state.node_name} lost cluster leadership")
    end

    %{state | is_leader: false}
  end

  defp sweep_orphaned_jobs do
    # When the node is leader, sweep jobs that are running but have no valid lease.
    case RedisStore.list_jobs() do
      {:ok, jobs} ->
        for job <- jobs,
            job["status"] in ["pending", "running", "paused"],
            recoverable_on_cluster?(job) do
          check_job_lease(job["job_id"])
        end

      _ ->
        :ok
    end
  end

  defp check_job_lease(job_id) do
    lease_name = "job:#{job_id}"

    case RedisStore.get_lease(lease_name) do
      {:ok, nil} ->
        Logger.info("Job #{job_id} has no active lease. Leader is re-assigning...")
        # Start the job on the cluster (Horde will distribute it)
        start_job_on_cluster(job_id)

      _ ->
        :ok
    end
  end

  defp start_job_on_cluster(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job_map} ->
        manifest_ref = job_map["manifest_ref"] || %{}
        job_path = manifest_ref["job_path"]

        if job_path do
          case MirrorNeuron.JobBundle.load(job_path) do
            {:ok, bundle} ->
              spec =
                {MirrorNeuron.Runtime.JobRunner, {job_id, bundle.manifest, [job_bundle: bundle]}}

              case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
                {:ok, _pid} -> :ok
                {:error, {:already_started, _pid}} -> :ok
                _ -> :ok
              end

            {:error, reason} ->
              Logger.warning("Leader could not load job bundle for #{job_id}: #{inspect(reason)}")
          end
        else
          Logger.warning(
            "No job_path found in manifest_ref for orphaned job #{job_id}, cannot re-assign."
          )
        end

      _ ->
        :ok
    end
  end

  defp recoverable_on_cluster?(job) do
    Map.get(job, "recovery_policy", "local_restart") == "cluster_recover"
  end
end
