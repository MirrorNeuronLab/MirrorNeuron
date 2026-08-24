defmodule MirrorNeuron.Runtime.CancellationReconciler do
  @moduledoc false

  use GenServer

  require Logger

  alias MirrorNeuron.Persistence.{CancellationStore, CheckpointLock, DiskCheckpoint, RedisStore}
  alias MirrorNeuron.Runner.{DockerCompose, HostLocal}
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Sandbox.{DockerJobSandbox, OpenShellJobSandbox}
  alias MirrorNeuron.ServiceRegistry

  @scan_interval_ms 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def kick do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :scan)
    else
      :ok
    end
  end

  def reconcile_now(job_id) when is_binary(job_id) do
    reconcile_cancellation(job_id, to_string(Node.self()))
  end

  @impl true
  def init(_opts) do
    case ensure_checkpoint_lock() do
      :ok ->
        Process.send_after(self(), :scan, 250)
        {:ok, :ok}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast(:scan, state) do
    scan()
    {:noreply, state}
  end

  @impl true
  def handle_info(:scan, state) do
    scan()
    Process.send_after(self(), :scan, @scan_interval_ms)
    {:noreply, state}
  end

  defp scan do
    local_node = to_string(Node.self())

    case CancellationStore.list_pending_for_node(local_node) do
      {:ok, cancellations} ->
        Enum.each(cancellations, &reconcile_cancellation(&1["job_id"], local_node))

      {:error, reason} ->
        Logger.warning("could not scan durable cancellations: #{inspect(reason)}")
    end
  end

  defp reconcile_cancellation(job_id, local_node) do
    # A stale coordinator is allowed to receive the cancellation and stop, but
    # cannot persist a write after the request fence has advanced.
    try do
      # Compose teardown is independent of the legacy sandbox registry.  In
      # particular, after a Core restart there may be no HostLocal process to
      # terminate, but the persisted project must still be brought down.
      with :ok <- cleanup_prepared_compose_projects(job_id),
           :ok <- HostLocal.terminate_job(job_id),
           :ok <- stop_local_job(job_id),
           :ok <- ServiceRegistry.deregister_job(job_id),
           :ok <- OpenShellJobSandbox.cleanup_job_local(job_id),
           :ok <- DockerJobSandbox.cleanup_job_local(job_id),
           :ok <- DiskCheckpoint.delete_job(job_id) do
        case CancellationStore.acknowledge(job_id, local_node) do
          {:ok, :completed, _cancellation} ->
            EventBus.publish_if_job_exists(job_id, %{
              type: :job_cancelled,
              reason: "durable cluster cancellation acknowledged",
              timestamp: Runtime.timestamp()
            })

            :ok

          {:ok, :pending, _cancellation} ->
            EventBus.publish_if_job_exists(job_id, %{
              type: :job_cancellation_acknowledged,
              node: local_node,
              timestamp: Runtime.timestamp()
            })

            :ok

          {:ok, :not_target, _cancellation} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "could not acknowledge durable cancellation for #{job_id}: #{inspect(reason)}"
            )
        end
      else
        {:error, reason} ->
          Logger.warning(
            "durable cancellation cleanup is incomplete for #{job_id}; acknowledgement will retry: #{inspect(reason)}"
          )
      end
    rescue
      error ->
        Logger.warning(
          "durable cancellation reconciliation failed for #{job_id}: #{Exception.message(error)}"
        )
    catch
      kind, reason ->
        Logger.warning(
          "durable cancellation reconciliation failed for #{job_id}: #{inspect({kind, reason})}"
        )
    end
  end

  defp stop_local_job(job_id) do
    Runtime.terminate_local_job(job_id)
  end

  # A cancellation can be reconciled after its JobCoordinator has exited or
  # after Core has restarted.  The prepared Compose record lives in the
  # persisted manifest/topology, so use it rather than relying on a live
  # runner process.  DockerCompose only ever tears down that exact project.
  defp cleanup_prepared_compose_projects(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job} when is_map(job) ->
        job
        |> compose_configs_from_job()
        |> Enum.reduce_while(:ok, fn config, :ok ->
          case DockerCompose.cleanup_prepared_project(config) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:docker_compose_cleanup, reason}}}
          end
        end)

      _ ->
        :ok
    end
  end

  defp compose_configs_from_job(job) do
    topology_nodes = fn topology -> List.wrap(detail(topology, "nodes")) end

    [
      detail(job, "runtime_topology") |> topology_nodes.(),
      detail(job, "topology") |> topology_nodes.(),
      job |> detail("manifest") |> detail("agents") |> topology_nodes.()
    ]
    |> List.flatten()
    |> Enum.map(fn node -> if is_map(node), do: detail(node, "config"), else: nil end)
    |> Enum.filter(fn config ->
      is_map(config) and is_map(detail(config, "mn_docker_compose"))
    end)
    |> Enum.uniq_by(fn config ->
      config
      |> detail("mn_docker_compose")
      |> detail("project_name")
    end)
  end

  defp detail(map, "runtime_topology") when is_map(map),
    do: Map.get(map, "runtime_topology") || Map.get(map, :runtime_topology)

  defp detail(map, "nodes") when is_map(map),
    do: Map.get(map, "nodes") || Map.get(map, :nodes)

  defp detail(map, "config") when is_map(map),
    do: Map.get(map, "config") || Map.get(map, :config)

  defp detail(map, "agents") when is_map(map),
    do: Map.get(map, "agents") || Map.get(map, :agents)

  defp detail(map, "mn_docker_compose") when is_map(map),
    do: Map.get(map, "mn_docker_compose") || Map.get(map, :mn_docker_compose)

  defp detail(map, "project_name") when is_map(map),
    do: Map.get(map, "project_name") || Map.get(map, :project_name)

  defp detail(_map, _key), do: nil

  defp ensure_checkpoint_lock do
    case Process.whereis(CheckpointLock) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case CheckpointLock.start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
