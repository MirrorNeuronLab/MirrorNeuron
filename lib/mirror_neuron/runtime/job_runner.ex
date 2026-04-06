defmodule MirrorNeuron.Runtime.JobRunner do
  use GenServer
  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.JobCoordinator
  alias MirrorNeuron.Runtime.Naming

  @terminal_statuses ["completed", "failed", "cancelled"]

  def child_spec({job_id, manifest, opts}) do
    %{
      id: {:job_runner, job_id},
      start: {__MODULE__, :start_link, [{job_id, manifest, opts}]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link({job_id, manifest, opts}) do
    GenServer.start_link(__MODULE__, {job_id, manifest, opts},
      name: Naming.via_job_runner(job_id)
    )
  end

  @impl true
  def init({job_id, manifest, opts}) do
    Process.flag(:trap_exit, true)

    lease_name = "job:#{job_id}"
    node_name = to_string(Node.self())

    case RedisStore.acquire_lease(lease_name, node_name, 10_000) do
      :ok ->
        :ok

      {:error, :locked} ->
        case RedisStore.renew_lease(lease_name, node_name, 10_000) do
          :ok -> :ok
          _ -> exit(:normal)
        end

      _ ->
        :ok
    end

    :timer.send_interval(3_000, :renew_lease)

    case JobCoordinator.start_link({job_id, manifest, opts}) do
      {:ok, pid} ->
        {:ok,
         %{
           job_id: job_id,
           manifest: manifest,
           bundle: Keyword.get(opts, :job_bundle),
           coordinator: pid,
           node_name: node_name
         }}

      {:error, reason} ->
        Logger.warning("failed to start job coordinator for #{job_id}: #{inspect(reason)}")
        persist_runner_failure(job_id, manifest, Keyword.get(opts, :job_bundle), reason)
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:renew_lease, state) do
    lease_name = "job:#{state.job_id}"

    case RedisStore.renew_lease(lease_name, state.node_name, 10_000) do
      :ok ->
        {:noreply, state}

      {:error, :not_owner} ->
        Logger.warning("Lost lease for job #{state.job_id}. Shutting down.")
        {:stop, :normal, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{coordinator: pid} = state) do
    persist_missing_terminal_state(state, reason)

    stop_reason =
      case reason do
        :normal -> :normal
        :shutdown -> :normal
        other -> {:shutdown, other}
      end

    {:stop, stop_reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    lease_name = "job:#{state.job_id}"
    _ = RedisStore.release_lease(lease_name, state.node_name)
    :ok
  end

  defp persist_missing_terminal_state(state, reason) do
    case RedisStore.fetch_job(state.job_id) do
      {:ok, %{"status" => status}} when status in @terminal_statuses ->
        :ok

      _ ->
        Logger.warning(
          "job coordinator for #{state.job_id} exited before terminal persistence: #{inspect(reason)}"
        )

        persist_runner_failure(state.job_id, state.manifest, state.bundle, reason)
    end
  end

  defp persist_runner_failure(job_id, manifest, bundle, reason) do
    defaults = %{
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "root_agent_ids" => manifest.entrypoints,
      "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
      "recovery_policy" => Map.get(manifest.policies, "recovery_mode", "local_restart"),
      "manifest_ref" => %{
        "graph_id" => manifest.graph_id,
        "manifest_version" => manifest.manifest_version,
        "manifest_path" => bundle && bundle.manifest_path,
        "job_path" => bundle && bundle.root_path
      },
      "submitted_at" => Runtime.timestamp()
    }

    updates = %{
      "status" => "failed",
      "result" => %{
        "agent_id" => "job_runner",
        "error" => "job coordinator exited before terminal state",
        "reason" => inspect(reason)
      }
    }

    case RedisStore.persist_terminal_job(job_id, updates, defaults) do
      {:ok, _job} ->
        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to persist job runner fallback state for #{job_id}: #{inspect(persist_reason)}"
        )
    end
  end
end
