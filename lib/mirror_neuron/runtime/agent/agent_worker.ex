defmodule MirrorNeuron.Runtime.AgentWorker do
  use GenServer

  @moduledoc "Supervised agent process with explicit pause, delivery and heartbeat callbacks."

  alias MirrorNeuron.AgentRegistry
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.AgentWorker.Context
  alias MirrorNeuron.Runtime.AgentWorker.Deliveries
  alias MirrorNeuron.Runtime.AgentWorker.Observations
  alias MirrorNeuron.Runtime.AgentWorker.Timers
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.Naming

  def child_spec(
        {job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context,
         recovery_snapshot}
      ) do
    %{
      id: {:agent_worker, job_id, node.node_id},
      start:
        {__MODULE__, :start_link,
         [
           {job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context,
            recovery_snapshot}
         ]},
      restart: :temporary,
      type: :worker
    }
  end

  def child_spec({job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context}) do
    child_spec({job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context, nil})
  end

  def start_link(
        {job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context,
         recovery_snapshot}
      ) do
    GenServer.start_link(
      __MODULE__,
      {job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context,
       recovery_snapshot},
      name: Naming.via_agent(job_id, node.node_id)
    )
  end

  def start_link({job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context}) do
    start_link({job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context, nil})
  end

  @impl true
  def init(
        {job_id, node, outbound_edges, inbound_edges, coordinator, runtime_context,
         recovery_snapshot}
      ) do
    module = AgentRegistry.fetch!(node.agent_type)

    runtime_context = Context.materialize_runtime_bundle_context(runtime_context)
    node = Context.inject_runtime_paths(node, runtime_context)
    paused? = Context.recovery_flag?(recovery_snapshot, "paused", :paused)

    reclaim_deliveries? =
      Context.recovery_flag?(recovery_snapshot, "reclaim_deliveries", :reclaim_deliveries)

    service_resume_token =
      if is_map(recovery_snapshot) and MirrorNeuron.Runner.resumable_after_stop?(node.config),
        do: recovery_snapshot["service_resume_token"]

    case module.init(node) do
      {:ok, local_state} ->
        state = %{
          job_id: job_id,
          node: node,
          module: module,
          local_state: local_state,
          outbound_edges: outbound_edges,
          inbound_edges: inbound_edges,
          runtime_context: runtime_context,
          coordinator: coordinator,
          paused?: paused?,
          pending: :queue.new(),
          mailbox_depth: 0,
          command_streak: 0,
          checkpoint_pending?: false,
          delivery_bucket: node.node_id,
          service_resume_token: service_resume_token,
          processed_messages: 0,
          inflight_message: nil,
          heartbeat_interval_ms: Timers.heartbeat_interval_ms(),
          heartbeat_timer_ref: nil,
          heartbeat_token: nil,
          delivery_consumer: Delivery.consumer_id(job_id, node.node_id),
          delivery_group_ready?: false,
          next_delivery_reclaim_at_ms: 0,
          delivery_retries: %{},
          delivery_timer_ref: nil,
          delivery_token: nil,
          reclaim_deliveries?: reclaim_deliveries?,
          pressure_snapshot: nil
        }

        MirrorNeuron.Runtime.ErrorMonitor.watch(self(), job_id, node.node_id)

        with {:ok, state} <- MirrorNeuron.Runtime.InvocationOutbox.recover(state) do
          state = Timers.schedule_heartbeat(state)
          Observations.persist_observation(state)
          {:ok, state, {:continue, :start}}
        else
          {:error, :checkpoint_artifact_pending} ->
            {:ok, %{state | checkpoint_pending?: true}, {:continue, :start}}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start, state),
    do: {:noreply, Timers.schedule_delivery_poll(state, 0)}

  @impl true
  def handle_cast(:pause, state) do
    next_state =
      state
      |> Timers.cancel_delivery_timer()
      |> Map.put(:paused?, true)

    Observations.persist_observation(next_state)
    {:noreply, next_state}
  end

  def handle_cast(:resume, state) do
    next_state = %{state | paused?: false}
    Observations.persist_observation(next_state)
    {:noreply, Timers.schedule_delivery_poll(next_state, 0)}
  end

  def handle_cast(:cancel, state), do: {:stop, :normal, state}

  def handle_cast({:deliver, message}, state) do
    _result = Runtime.deliver(state.job_id, state.node.node_id, message)
    {:noreply, state}
  end

  def handle_cast(:delivery_available, %{paused?: true} = state) do
    Observations.persist_observation(state)
    {:noreply, state}
  end

  def handle_cast(:delivery_available, state),
    do: {:noreply, Timers.schedule_delivery_poll(state, 0)}

  @impl true
  def handle_call(:pressure_snapshot, _from, state) do
    snapshot = Observations.pressure_snapshot(state, Observations.durable_delivery_depth(state))
    {:reply, snapshot, %{state | pressure_snapshot: snapshot}}
  end

  @impl true
  def handle_info({:heartbeat, token}, %{heartbeat_token: token} = state) do
    state = Timers.clear_heartbeat_timer(state)
    Observations.persist_observation(state)
    {:noreply, Timers.schedule_heartbeat(state)}
  end

  def handle_info({:heartbeat, _stale_token}, state), do: {:noreply, state}

  def handle_info(:heartbeat, state) do
    Observations.persist_observation(state)
    {:noreply, state}
  end

  def handle_info({:delivery_poll, token}, %{delivery_token: token} = state) do
    state = Timers.clear_delivery_timer(state)

    if state.paused? do
      {:noreply, state}
    else
      {:noreply, Deliveries.poll_deliveries(state)}
    end
  end

  def handle_info({:delivery_poll, _stale_token}, state), do: {:noreply, state}

  def handle_info({:mirror_neuron_scheduled_message, message}, state) do
    _result = Runtime.deliver(state.job_id, state.node.node_id, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Timers.cancel_heartbeat_timer(state)
    Timers.cancel_delivery_timer(state)
    :ok
  end
end
