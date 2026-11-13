defmodule MirrorNeuron.Runtime.JobRunner do
  use GenServer

  @moduledoc "Supervised run owner; starts one coordinator and fences it with a renewable lease."

  alias MirrorNeuron.Runtime.JobRunner.Failures
  alias MirrorNeuron.Runtime.JobRunner.Leases
  alias MirrorNeuron.Runtime.Naming
  alias MirrorNeuron.Runtime.JobRunner.Processes
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.JobRunner.Startup

  defdelegate lease_duration_ms(), to: Leases
  defdelegate lease_renew_interval_ms(), to: Leases

  def child_spec({job_id, manifest, opts}) do
    %{
      id: {:job_runner, job_id},
      start: {__MODULE__, :start_link, [{job_id, manifest, opts}]},
      restart: :transient,
      type: :worker
    }
    |> put_target_node(Keyword.get(opts, :preferred_start_node))
  end

  defp put_target_node(spec, nil), do: spec

  defp put_target_node(spec, ""), do: spec

  defp put_target_node(spec, node_name) do
    Map.put(spec, :mirror_neuron_target_node, to_string(node_name))
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
    opts = Startup.put_bundle_ref(opts, manifest)

    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => "cancelling"}} ->
        Startup.stop_normally(job_id, manifest, opts)

      _ ->
        Startup.acquire_and_start_coordinator(job_id, manifest, opts, lease_name, node_name)
    end
  end

  @impl true
  def handle_continue(:stop_normally, state), do: {:stop, :normal, state}

  @impl true
  def handle_info(:start_attempt_coordinator, state) do
    case Startup.start_attempt_coordinator(state) do
      {:ok, next_state} -> {:noreply, next_state}
      {:stop, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:renew_lease, token}, %{lease_timer_token: token} = state) do
    state = Leases.clear_lease_timer(state)
    Leases.renew_lease(state, true)
  end

  def handle_info({:renew_lease, _stale_token}, state), do: {:noreply, state}

  def handle_info(:renew_lease, state), do: Leases.renew_lease(state, false)

  def handle_info({:EXIT, pid, reason}, %{coordinator: pid} = state) do
    exit_action = Failures.classify_coordinator_exit(state, reason)

    stop_reason = if exit_action == :restart, do: {:coordinator_exit, reason}, else: :normal

    {:stop, stop_reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Processes.cancel_coordinator_start_timer(state)
    Leases.cancel_lease_timer(state)
    Processes.stop_coordinator(state.coordinator)
    Leases.release_job_lease(state.job_id, state.node_name, state.lease)
    :ok
  end
end
