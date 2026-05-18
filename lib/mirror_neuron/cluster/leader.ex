defmodule MirrorNeuron.Cluster.Leader do
  use GenServer
  require Logger

  alias MirrorNeuron.Persistence.RedisStore

  @lease_duration_ms 10_000
  @refresh_interval_ms 3_000
  @sweep_interval_ms 5_000
  @node_down_sweep_delay_ms 11_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep_now, 15_000)
  end

  def node_down(node, server \\ __MODULE__) do
    GenServer.cast(server, {:node_down, to_string(node)})
  end

  @impl true
  def init(:ok) do
    state = %{
      is_leader: false,
      node_name: to_string(Node.self()),
      sweep_ref: nil
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

  def handle_info(:sweep_orphaned_jobs, %{is_leader: true} = state) do
    _ = sweep_orphaned_jobs()
    {:noreply, schedule_sweep(state)}
  end

  def handle_info(:sweep_orphaned_jobs, state), do: {:noreply, %{state | sweep_ref: nil}}

  def handle_info({:sweep_orphaned_jobs, node_name}, %{is_leader: true} = state) do
    _ = sweep_orphaned_jobs(node_name)
    {:noreply, state}
  end

  def handle_info({:sweep_orphaned_jobs, _node_name}, state), do: {:noreply, state}

  @impl true
  def handle_call(:sweep_now, _from, state) do
    result =
      if state.is_leader, do: sweep_orphaned_jobs(), else: %{checked: 0, recovered: 0, failed: 0}

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_cast({:node_down, node_name}, state) do
    if state.is_leader do
      Process.send_after(self(), {:sweep_orphaned_jobs, node_name}, @node_down_sweep_delay_ms)
    end

    {:noreply, state}
  end

  defp handle_became_leader(state) do
    if not state.is_leader do
      Logger.notice("Node #{state.node_name} became cluster leader")
    end

    _ = sweep_orphaned_jobs()
    state |> Map.put(:is_leader, true) |> schedule_sweep()
  end

  defp handle_lost_leadership(state) do
    if state.is_leader do
      Logger.notice("Node #{state.node_name} lost cluster leadership")
    end

    cancel_sweep(state)
    %{state | is_leader: false, sweep_ref: nil}
  end

  defp sweep_orphaned_jobs(owner_node \\ nil) do
    # When the node is leader, sweep jobs that are running but have no valid lease.
    case RedisStore.list_jobs() do
      {:ok, jobs} ->
        jobs
        |> Enum.filter(fn job -> job["status"] in ["pending", "running", "paused"] end)
        |> Enum.filter(fn job -> is_nil(owner_node) or job["lease_owner"] == owner_node end)
        |> Enum.reduce(%{checked: 0, recovered: 0, failed: 0}, fn job, acc ->
          update_sweep_counts(acc, check_job_lease(job))
        end)

      _ ->
        %{checked: 0, recovered: 0, failed: 0}
    end
  end

  defp check_job_lease(job) do
    job_id = job["job_id"]
    lease_name = "job:#{job_id}"

    case RedisStore.get_lease(lease_name) do
      {:ok, nil} ->
        if safe_to_sweep?(job) do
          cond do
            recoverable_on_cluster?(job) ->
              Logger.info("Job #{job_id} has no active lease. Leader is re-assigning...")
              # Start the job on the cluster (Horde will distribute it)
              case start_job_on_cluster(job_id) do
                :ok -> :recovered
                _ -> :checked
              end

            recoverable_locally?(job) ->
              Logger.info(
                "Job #{job_id} has no active lease and is configured for local recovery. Leaving it for local startup recovery."
              )

              MirrorNeuron.Runtime.EventBus.publish(job_id, %{
                type: :local_recovery_waiting,
                reason: "job requires local recovery on its original machine",
                timestamp: MirrorNeuron.Runtime.timestamp()
              })

              :checked

            true ->
              Logger.info(
                "Job #{job_id} has no active lease and is not cluster-recoverable. Marking as failed."
              )

              fail_orphaned_job(job_id)
              :failed
          end
        else
          :checked
        end

      _ ->
        :checked
    end
  end

  defp safe_to_sweep?(job) do
    # Prevent sweeping a job that was *just* submitted and hasn't acquired a lease yet.
    # If the job is older than 15 seconds, it should definitely have a lease if it's active.
    case DateTime.from_iso8601(job["updated_at"] || job["submitted_at"] || "") do
      {:ok, dt, _offset} ->
        diff = DateTime.diff(DateTime.utc_now(), dt, :millisecond)
        diff > 15_000

      _ ->
        true
    end
  end

  defp fail_orphaned_job(job_id) do
    now = MirrorNeuron.Runtime.timestamp()

    RedisStore.persist_terminal_job(job_id, %{
      "status" => "failed",
      "error" => "Node running the job died and job is not configured for cluster recovery."
    })

    MirrorNeuron.Runtime.EventBus.publish(job_id, %{
      type: :job_failed,
      reason: "Node running the job died and job is not configured for cluster recovery.",
      timestamp: now
    })
  end

  defp start_job_on_cluster(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job_map} ->
        case load_recovery_bundle(job_map) do
          {:ok, bundle} ->
            spec =
              {MirrorNeuron.Runtime.JobRunner,
               {job_id, bundle.manifest,
                [
                  job_bundle: bundle,
                  requested_recovery_policy: job_map["requested_recovery_policy"],
                  recovery_policy: job_map["recovery_policy"],
                  reliability: job_map["reliability"]
                ]}}

            case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
              {:ok, _pid} ->
                MirrorNeuron.Runtime.EventBus.publish(job_id, %{
                  type: :job_relocated,
                  reason: "lost job lease",
                  timestamp: MirrorNeuron.Runtime.timestamp()
                })

                :ok

              {:error, {:already_started, _pid}} ->
                :ok

              {:error, reason} ->
                Logger.warning("Leader could not restart job #{job_id}: #{inspect(reason)}")
                {:error, reason}
            end

          {:error, reason} ->
            Logger.warning(
              "Leader could not load recovery bundle for #{job_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      _ ->
        {:error, :missing_job}
    end
  end

  defp recoverable_on_cluster?(job) do
    Map.get(job, "recovery_policy", "local_restart") == "cluster_recover"
  end

  defp recoverable_locally?(job) do
    Map.get(job, "recovery_policy", "local_restart") in ["local_restart", "manual_recover"]
  end

  defp load_recovery_bundle(job_map) do
    manifest_ref = job_map["manifest_ref"] || %{}
    fingerprint = manifest_ref["bundle_fingerprint"]
    job_path = manifest_ref["job_path"]

    cond do
      is_binary(fingerprint) and fingerprint != "" ->
        case MirrorNeuron.Bundle.Archive.load(fingerprint) do
          {:ok, bundle} ->
            {:ok, bundle}

          {:error, _reason} when is_binary(job_path) ->
            MirrorNeuron.JobBundle.load_filesystem_path(job_path)

          {:error, reason} ->
            {:error, reason}
        end

      is_binary(job_path) ->
        MirrorNeuron.JobBundle.load_filesystem_path(job_path)

      true ->
        {:error, :missing_bundle_reference}
    end
  end

  defp update_sweep_counts(acc, :recovered) do
    acc |> Map.update!(:checked, &(&1 + 1)) |> Map.update!(:recovered, &(&1 + 1))
  end

  defp update_sweep_counts(acc, :failed) do
    acc |> Map.update!(:checked, &(&1 + 1)) |> Map.update!(:failed, &(&1 + 1))
  end

  defp update_sweep_counts(acc, _other), do: Map.update!(acc, :checked, &(&1 + 1))

  defp schedule_sweep(state) do
    cancel_sweep(state)
    %{state | sweep_ref: Process.send_after(self(), :sweep_orphaned_jobs, @sweep_interval_ms)}
  end

  defp cancel_sweep(%{sweep_ref: ref}) when is_reference(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cancel_sweep(_state), do: :ok
end
