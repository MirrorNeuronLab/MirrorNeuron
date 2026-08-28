defmodule MirrorNeuron.Runtime.CancellationReconciler do
  @moduledoc false

  use GenServer

  require Logger

  alias MirrorNeuron.Persistence.{CancellationStore, RedisStore}
  alias MirrorNeuron.Runner.HostLocal
  alias MirrorNeuron.Runtime.RunnerResources
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
    Process.send_after(self(), :scan, 250)
    {:ok, :ok}
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
      # Native Docker resources are independent of the sandbox registry. In
      # particular, after a Core restart there may be no
      # HostLocal process to terminate, but persisted DockerWorker containers
      # and DockerCompose projects must still be brought down.
      with :ok <- cleanup_prepared_compose_projects(job_id),
           :ok <- cleanup_docker_worker(job_id),
           :ok <- RunnerResources.cleanup_native_resources(job_id),
           :ok <- HostLocal.terminate_job(job_id),
           :ok <- stop_local_job(job_id),
           :ok <- ServiceRegistry.deregister_job(job_id),
           :ok <- OpenShellJobSandbox.cleanup_job_local(job_id),
           :ok <- DockerJobSandbox.cleanup_job_local(job_id) do
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
        RunnerResources.cleanup_prepared_compose_projects(job)

      _ ->
        :ok
    end
  end

  defp cleanup_docker_worker(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, job} when is_map(job) ->
        if RunnerResources.docker_worker?(job),
          do: RunnerResources.cleanup_docker_worker(job_id),
          else: :ok

      _ ->
        :ok
    end
  end
end
