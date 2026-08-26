defmodule MirrorNeuron.Runtime.AgentWorker do
  use GenServer
  require Logger

  alias MirrorNeuron.AgentRegistry
  alias MirrorNeuron.Message
  alias MirrorNeuron.Bundle.Archive, as: BundleArchive
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ResourceSpec
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Backpressure
  alias MirrorNeuron.Runtime.Delivery
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Runtime.Naming
  alias MirrorNeuron.Runtime.RouteCondition
  alias MirrorNeuron.Scheduler

  @default_heartbeat_interval_ms 30_000
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

    runtime_context = materialize_runtime_bundle_context(runtime_context)
    node = inject_runtime_paths(node, runtime_context)
    paused? = recovery_flag?(recovery_snapshot, "paused", :paused)

    reclaim_deliveries? =
      recovery_flag?(recovery_snapshot, "reclaim_deliveries", :reclaim_deliveries)

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
          processed_messages: 0,
          inflight_message: nil,
          heartbeat_interval_ms: heartbeat_interval_ms(),
          heartbeat_timer_ref: nil,
          heartbeat_token: nil,
          delivery_consumer: Delivery.consumer_id(job_id, node.node_id),
          delivery_group_ready?: false,
          next_delivery_reclaim_at_ms: 0,
          delivery_timer_ref: nil,
          delivery_token: nil,
          reclaim_deliveries?: reclaim_deliveries?,
          pressure_snapshot: nil
        }

        state = schedule_heartbeat(state)
        persist_observation(state)
        {:ok, state, {:continue, :start}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start, state),
    do: {:noreply, schedule_delivery_poll(state, 0)}

  @impl true
  def handle_cast(:pause, state) do
    next_state =
      state
      |> cancel_delivery_timer()
      |> Map.put(:paused?, true)

    persist_observation(next_state)
    {:noreply, next_state}
  end

  def handle_cast(:resume, state) do
    next_state = %{state | paused?: false}
    persist_observation(next_state)
    {:noreply, schedule_delivery_poll(next_state, 0)}
  end

  def handle_cast(:cancel, state), do: {:stop, :normal, state}

  def handle_cast({:deliver, message}, state) do
    _result = Runtime.deliver(state.job_id, state.node.node_id, message)
    {:noreply, state}
  end

  def handle_cast(:delivery_available, %{paused?: true} = state) do
    persist_observation(state)
    {:noreply, state}
  end

  def handle_cast(:delivery_available, state),
    do: {:noreply, schedule_delivery_poll(state, 0)}

  @impl true
  def handle_call(:pressure_snapshot, _from, state) do
    snapshot = pressure_snapshot(state)
    {:reply, snapshot, %{state | pressure_snapshot: snapshot}}
  end

  @impl true
  def handle_info({:heartbeat, token}, %{heartbeat_token: token} = state) do
    state = clear_heartbeat_timer(state)
    persist_observation(state)
    {:noreply, schedule_heartbeat(state)}
  end

  def handle_info({:heartbeat, _stale_token}, state), do: {:noreply, state}

  def handle_info(:heartbeat, state) do
    persist_observation(state)
    {:noreply, state}
  end

  def handle_info({:delivery_poll, token}, %{delivery_token: token} = state) do
    state = clear_delivery_timer(state)

    if state.paused? do
      {:noreply, state}
    else
      {:noreply, poll_deliveries(state)}
    end
  end

  def handle_info({:delivery_poll, _stale_token}, state), do: {:noreply, state}

  def handle_info({:mirror_neuron_scheduled_message, message}, state) do
    _result = Runtime.deliver(state.job_id, state.node.node_id, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_heartbeat_timer(state)
    cancel_delivery_timer(state)
    :ok
  end

  defp poll_deliveries(state) do
    reclaim? = delivery_reclaim_due?(state)

    case Delivery.read(
           state.job_id,
           state.node.node_id,
           state.delivery_consumer,
           reclaim: state.reclaim_deliveries?,
           claim_stale: reclaim?,
           ensure_group: not state.delivery_group_ready?
         ) do
      {:ok, []} ->
        state
        |> mark_delivery_poll_succeeded(reclaim?)
        |> schedule_delivery_poll(Delivery.poll_ms())

      {:ok, [delivery | _rest]} ->
        state = mark_delivery_poll_succeeded(state, reclaim?)

        delivery
        |> process_delivery(state)
        |> schedule_delivery_poll(0)

      {:error, reason} ->
        Logger.warning("failed to poll durable message deliveries",
          job_id: state.job_id,
          agent_id: state.node.node_id,
          reason: inspect(reason)
        )

        state
        |> Map.put(:delivery_group_ready?, false)
        |> schedule_delivery_poll(Delivery.poll_ms())
    end
  end

  defp delivery_reclaim_due?(state) do
    state.reclaim_deliveries? or
      System.monotonic_time(:millisecond) >= state.next_delivery_reclaim_at_ms
  end

  defp mark_delivery_poll_succeeded(state, reclaim?) do
    next_reclaim_at_ms =
      if reclaim? do
        System.monotonic_time(:millisecond) + Delivery.lease_ms()
      else
        state.next_delivery_reclaim_at_ms
      end

    %{
      state
      | reclaim_deliveries?: false,
        delivery_group_ready?: true,
        next_delivery_reclaim_at_ms: next_reclaim_at_ms
    }
  end

  defp process_delivery(%{discard_reason: reason} = delivery, state) do
    _result = Delivery.dead_letter(state.job_id, state.node.node_id, delivery, reason)
    state
  end

  defp process_delivery(delivery, state) do
    message = put_in(delivery.message, ["envelope", "attempt"], delivery.attempt)
    delivery = %{delivery | message: message}

    renewer =
      Delivery.start_lease_renewer(
        state.job_id,
        state.node.node_id,
        state.delivery_consumer,
        delivery.stream_id
      )

    result = process_message_result(message, state)
    Delivery.stop_lease_renewer(renewer)

    case result do
      {:ok, next_state} ->
        retry_result =
          case Delivery.ack(
                 state.job_id,
                 state.node.node_id,
                 state.delivery_consumer,
                 delivery
               ) do
            :ok ->
              persist_observation(next_state)

              send(state.coordinator, {
                :agent_event,
                state.node.node_id,
                :message_acked,
                %{"message_id" => delivery.message_id, "attempt" => delivery.attempt}
              })

              :no_retry

            {:error, reason} ->
              report_delivery_retry(delivery, {:ack_failed, reason}, state)
          end

        schedule_delivery_reclaim(next_state, retry_result)

      {:error, reason, next_state} ->
        retry_result = report_delivery_retry(delivery, reason, state)
        send(state.coordinator, {:agent_failed, state.node.node_id, reason})
        schedule_delivery_reclaim(next_state, retry_result)
    end
  end

  defp report_delivery_retry(delivery, reason, state) do
    result =
      Delivery.retry(
        state.job_id,
        state.node.node_id,
        state.delivery_consumer,
        delivery
      )

    send(state.coordinator, {
      :agent_event,
      state.node.node_id,
      :message_retry_scheduled,
      %{
        "message_id" => delivery.message_id,
        "attempt" => delivery.attempt,
        "reason" => inspect(reason),
        "delay_ms" => retry_delay(result)
      }
    })

    result
  end

  defp schedule_delivery_reclaim(state, {:ok, delay_ms})
       when is_integer(delay_ms) and delay_ms >= 0 do
    %{
      state
      | reclaim_deliveries?: false,
        next_delivery_reclaim_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_delivery_reclaim(state, _retry_result), do: state

  defp retry_delay({:ok, delay_ms}) when is_integer(delay_ms), do: delay_ms
  defp retry_delay(_result), do: nil

  defp schedule_delivery_poll(%{paused?: true} = state, _delay_ms),
    do: cancel_delivery_timer(state)

  defp schedule_delivery_poll(state, delay_ms) do
    state = cancel_delivery_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:delivery_poll, token}, max(delay_ms, 0))
    %{state | delivery_timer_ref: timer_ref, delivery_token: token}
  end

  defp cancel_delivery_timer(%{delivery_timer_ref: ref, delivery_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:delivery_poll, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_delivery_timer(state)
  end

  defp cancel_delivery_timer(state), do: state

  defp clear_delivery_timer(state),
    do: %{state | delivery_timer_ref: nil, delivery_token: nil}

  defp process_message_result(message, state) do
    state = %{state | inflight_message: message}
    persist_observation(state)

    workflow = workflow_context(message, state)

    context = %{
      job_id: state.job_id,
      node: state.node,
      coordinator: state.coordinator,
      outbound_edges: state.outbound_edges,
      inbound_edges: state.inbound_edges,
      bundle_root: state.runtime_context[:bundle_root],
      manifest_path: state.runtime_context[:manifest_path],
      payloads_path: state.runtime_context[:payloads_path],
      artifact_refs: state.runtime_context[:artifact_refs] || [],
      template_type: Map.get(state.node, :type, "generic"),
      invocation: state.processed_messages + 1,
      workflow: workflow,
      coordinator_reporter: fn kind, fields, delivery_key ->
        enqueue_coordinator_report(state, message, kind, fields, delivery_key)
      end
    }

    with :ok <- maybe_report_workflow_message(state, message, workflow, "received") do
      EventBus.publish(state.job_id, %{
        type: :agent_message_received,
        agent_id: state.node.node_id,
        payload: Message.summary(message),
        attempt: state.runtime_context[:attempt],
        lease_epoch: state.runtime_context[:lease_epoch],
        timestamp: Runtime.timestamp()
      })

      handle_agent_message(message, state, context, workflow)
    else
      {:error, reason} ->
        persist_observation(state)
        {:error, {:coordinator_report_failed, reason}, state}
    end
  end

  defp handle_agent_message(message, state, context, workflow) do
    case state.module.handle_message(message, state.local_state, context) do
      {:ok, new_local_state, actions} ->
        next_state =
          %{
            state
            | local_state: new_local_state,
              processed_messages: state.processed_messages + 1,
              inflight_message: nil
          }

        case execute_actions(actions, message, next_state) do
          :ok ->
            case maybe_report_workflow_message(state, message, workflow, "acked") do
              :ok ->
                {:ok, next_state}

              {:error, reason} ->
                failed_state = %{state | inflight_message: message}
                persist_observation(failed_state)
                {:error, {:coordinator_report_failed, reason}, failed_state}
            end

          {:error, reason} ->
            failed_state = %{state | inflight_message: message}
            persist_observation(failed_state)
            {:error, {:output_delivery_failed, reason}, failed_state}
        end

      {:error, reason, new_local_state} ->
        failed_state = %{state | local_state: new_local_state, inflight_message: message}
        persist_observation(failed_state)
        {:error, reason, failed_state}
    end
  end

  defp execute_actions(actions, incoming, state) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {action, action_index}, :ok ->
      case execute_action(action, incoming, state, action_index) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_action({:emit, message_type, payload}, incoming, state, action_index) do
    execute_action({:emit, message_type, payload, []}, incoming, state, action_index)
  end

  defp execute_action({:emit, message_type, payload, opts}, incoming, state, action_index) do
    matching_edges =
      Enum.filter(state.outbound_edges, fn edge ->
        edge.message_type == message_type or edge.message_type == "*"
      end)

    route_context = RouteCondition.context(incoming, payload, state.local_state)

    evaluated_edges =
      Enum.map(matching_edges, &evaluate_route_edge(&1, message_type, route_context, state))

    selected_edges = select_route_edges(evaluated_edges)

    if matching_edges != [] and selected_edges == [] do
      send(state.coordinator, {
        :agent_event,
        state.node.node_id,
        :route_not_matched,
        %{
          "from" => state.node.node_id,
          "message_type" => message_type,
          "candidate_count" => length(matching_edges)
        }
      })
    end

    Enum.reduce_while(selected_edges, :ok, fn edge, :ok ->
      send(state.coordinator, {
        :agent_event,
        state.node.node_id,
        :route_selected,
        %{
          "edge_id" => edge.edge_id,
          "from" => edge.from_node,
          "to" => edge.to_node,
          "message_type" => message_type,
          "routing_mode" => edge.routing_mode
        }
      })

      delivery_opts = Keyword.put(opts, :delivery_key, "#{action_index}:#{edge.edge_id}")

      result =
        Runtime.deliver(
          state.job_id,
          edge.to_node,
          build_message(state, incoming, edge.to_node, message_type, payload, delivery_opts),
          target_backpressure_opts(state, edge.to_node)
        )

      maybe_report_delivery_pressure(result, edge.to_node, message_type, state)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_action({:emit_to, to_node, message_type, payload}, incoming, state, action_index) do
    execute_action(
      {:emit_to, to_node, message_type, payload, []},
      incoming,
      state,
      action_index
    )
  end

  defp execute_action(
         {:emit_to, to_node, message_type, payload, opts},
         incoming,
         state,
         action_index
       ) do
    delivery_opts = Keyword.put(opts, :delivery_key, Integer.to_string(action_index))

    result =
      Runtime.deliver(
        state.job_id,
        to_node,
        build_message(state, incoming, to_node, message_type, payload, delivery_opts),
        target_backpressure_opts(state, to_node)
      )

    maybe_report_delivery_pressure(result, to_node, message_type, state)
    result
  end

  defp execute_action({:emit_message, message}, incoming, state, action_index) do
    normalized = Message.normalize!(message, job_id: state.job_id, from: state.node.node_id)
    to_node = Message.to(normalized)
    message_id = deterministic_output_id(state, incoming, to_node, action_index)

    normalized =
      normalized
      |> put_in(["envelope", "message_id"], message_id)
      |> Map.update(
        "headers",
        with_attempt_epoch(Message.headers(normalized), state),
        fn headers ->
          with_attempt_epoch(headers || %{}, state)
        end
      )

    result =
      Runtime.deliver(state.job_id, to_node, normalized, target_backpressure_opts(state, to_node))

    maybe_report_delivery_pressure(
      result,
      to_node,
      Message.type(normalized),
      state
    )

    result
  end

  defp execute_action({:event, event_type, payload}, incoming, state, action_index) do
    normalized_event_type = to_string(event_type)
    payload = enrich_workflow_payload(payload, incoming)

    if Delivery.coordinator_event_requires_ack?(normalized_event_type) do
      enqueue_coordinator_report(
        state,
        incoming,
        "agent_event",
        %{"event_type" => normalized_event_type, "payload" => payload},
        action_index
      )
    else
      send(state.coordinator, {:agent_event, state.node.node_id, event_type, payload})
      :ok
    end
  end

  defp execute_action({:complete_step, result}, incoming, state, action_index) do
    enqueue_coordinator_report(
      state,
      incoming,
      "agent_event",
      %{
        "event_type" => "workflow_step_attempt_completed",
        "payload" => enrich_workflow_payload(result, incoming)
      },
      action_index
    )
  end

  defp execute_action({:complete_run, result}, incoming, state, action_index) do
    enqueue_coordinator_report(
      state,
      incoming,
      "agent_completed_run",
      %{"result" => result},
      action_index
    )
  end

  defp evaluate_route_edge(edge, message_type, route_context, state) do
    matched? = RouteCondition.matches?(edge.conditions, route_context)

    send(state.coordinator, {
      :agent_event,
      state.node.node_id,
      :route_evaluated,
      %{
        "edge_id" => edge.edge_id,
        "from" => edge.from_node,
        "to" => edge.to_node,
        "message_type" => message_type,
        "routing_mode" => edge.routing_mode,
        "matched" => matched?
      }
    })

    {edge, matched?}
  end

  defp select_route_edges(evaluated_edges) do
    matching = evaluated_edges |> Enum.filter(fn {_edge, matched?} -> matched? end)

    cond do
      Enum.any?(evaluated_edges, fn {edge, _matched?} -> edge.routing_mode == "first_match" end) ->
        matching |> Enum.take(1) |> Enum.map(fn {edge, _matched?} -> edge end)

      true ->
        Enum.map(matching, fn {edge, _matched?} -> edge end)
    end
  end

  defp persist_observation(state) do
    durable_depth = durable_delivery_depth(state)

    pressure = pressure_snapshot(state, durable_depth)
    observation = execution_observation(state.local_state)

    metadata = %{
      "paused" => state.paused?,
      "backpressure" => pressure,
      "pending_message_count" => durable_depth,
      "lease_epoch" => state.runtime_context[:lease_epoch],
      "lease_owner" => state.runtime_context[:lease_owner],
      "execution_profile" =>
        get_in(state.runtime_context, [:execution_profiles, state.node.node_id]) ||
          get_in(state.node, [:config, "execution_profile"])
    }

    observation = %{
      agent_id: state.node.node_id,
      node_id: state.node.node_id,
      agent_type: state.node.agent_type,
      type: Map.get(state.node, :type, "generic"),
      role: state.node.role,
      processed_messages: state.processed_messages,
      mailbox_depth: durable_depth,
      assigned_node: to_string(Node.self()),
      last_heartbeat_at: Runtime.timestamp(),
      parent_job_id: state.job_id,
      last_error: observation.last_error,
      sandbox: observation.sandbox,
      lease: observation.lease,
      metadata: metadata
    }

    case RedisStore.persist_agent(state.job_id, state.node.node_id, observation) do
      {:ok, _observation} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to persist agent observation for #{state.job_id}/#{state.node.node_id}: #{inspect(reason)}"
        )
    end

    send(state.coordinator, {:agent_pressure, state.node.node_id, pressure})
  end

  defp execution_observation(local_state) when is_map(local_state) do
    last_error = Map.get(local_state, :last_error) || Map.get(local_state, "last_error")
    last_result = Map.get(local_state, :last_result) || Map.get(local_state, "last_result")

    if is_map(last_result) do
      lease = Map.get(last_result, :lease) || Map.get(last_result, "lease") || %{}

      %{
        last_error: compact_observation_error(last_error),
        sandbox: %{
          "name" => Map.get(last_result, :sandbox_name) || Map.get(last_result, "sandbox_name"),
          "status" => Map.get(last_result, :status) || Map.get(last_result, "status")
        },
        lease: Map.take(stringify_observation_map(lease), ["lease_id", "pool", "slots"])
      }
    else
      %{last_error: compact_observation_error(last_error), sandbox: nil, lease: %{}}
    end
  end

  defp execution_observation(_local_state),
    do: %{last_error: nil, sandbox: nil, lease: %{}}

  defp compact_observation_error(nil), do: nil

  defp compact_observation_error(error) do
    encoded =
      if is_binary(error), do: error, else: inspect(error, limit: 50, printable_limit: 8_192)

    if byte_size(encoded) > 8_192, do: binary_part(encoded, 0, 8_192), else: encoded
  end

  defp stringify_observation_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp durable_delivery_depth(state) do
    case RedisStore.delivery_pending_count(state.job_id, state.node.node_id) do
      {:ok, count} -> count
      {:error, _reason} -> state.mailbox_depth
    end
  end

  defp pressure_snapshot(state, internal_depth \\ nil) do
    internal_depth = if is_nil(internal_depth), do: state.mailbox_depth, else: internal_depth
    queue_depth = Backpressure.process_queue_depth(self(), internal_depth)

    Backpressure.snapshot(
      state.node.node_id,
      state.node,
      queue_depth,
      [],
      state.pressure_snapshot
    )
  end

  defp maybe_report_delivery_pressure(:ok, _to_node, _message_type, _state), do: :ok

  defp maybe_report_delivery_pressure(
         {:error, {:backpressure, details}},
         to_node,
         message_type,
         state
       ) do
    send(state.coordinator, {
      :agent_event,
      state.node.node_id,
      :backpressure_signal,
      Map.merge(details, %{
        "from" => state.node.node_id,
        "to" => to_node,
        "message_type" => message_type
      })
    })
  end

  defp maybe_report_delivery_pressure({:error, reason}, to_node, message_type, state) do
    send(state.coordinator, {
      :agent_event,
      state.node.node_id,
      :delivery_failed,
      %{
        "from" => state.node.node_id,
        "to" => to_node,
        "message_type" => message_type,
        "reason" => inspect(reason)
      }
    })
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp maybe_report_workflow_message(_state, _message, workflow, _status)
       when map_size(workflow) == 0,
       do: :ok

  defp maybe_report_workflow_message(state, message, _workflow, status) do
    workflow_agent_steps = Map.get(state.runtime_context, :workflow_agent_steps, %{})

    if Map.has_key?(workflow_agent_steps, state.node.node_id) do
      enqueue_coordinator_report(
        state,
        message,
        "workflow_message_#{status}",
        %{"message" => Delivery.stable_workflow_message(message)},
        status
      )
    else
      :ok
    end
  end

  defp enqueue_coordinator_report(state, incoming, kind, fields, delivery_key) do
    report_id = coordinator_report_id(state, incoming, kind, delivery_key)

    body =
      fields
      |> Map.put("kind", kind)
      |> Map.put("agent_id", state.node.node_id)

    case Delivery.report(state.job_id, state.node.node_id, report_id, body,
           attempt_epoch: state.runtime_context[:lease_epoch]
         ) do
      :ok ->
        GenServer.cast(state.coordinator, :coordinator_delivery_available)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp coordinator_report_id(state, incoming, kind, delivery_key) do
    [state.job_id, state.node.node_id, Message.id(incoming), kind, to_string(delivery_key)]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp inject_runtime_paths(node, runtime_context) do
    allocation = Scheduler.allocation(runtime_context[:scheduler], node.node_id)

    runtime_config =
      node.config
      |> Map.put("__bundle_root", runtime_context[:bundle_root])
      |> Map.put("__manifest_path", runtime_context[:manifest_path])
      |> Map.put("__payloads_path", runtime_context[:payloads_path])
      |> Map.put("__artifact_refs", runtime_context[:artifact_refs] || [])
      |> Map.put("__mirror_neuron_allocation", allocation)
      |> put_artifact_environment(runtime_context[:artifact_refs] || [])
      |> put_allocation_environment(allocation)
      |> put_runtime_environment(runtime_context[:runtime_env] || %{})

    %{node | config: runtime_config}
  end

  defp materialize_runtime_bundle_context(runtime_context) when is_map(runtime_context) do
    if local_bundle_available?(runtime_context[:bundle_root]) do
      runtime_context
    else
      runtime_context
      |> bundle_fingerprint()
      |> load_archived_bundle(runtime_context)
    end
  end

  defp materialize_runtime_bundle_context(runtime_context), do: runtime_context

  defp local_bundle_available?(path) when is_binary(path) and path != "" do
    File.dir?(path)
  end

  defp local_bundle_available?(_path), do: false

  defp bundle_fingerprint(runtime_context) do
    manifest_ref = runtime_context[:manifest_ref]

    cond do
      is_map(manifest_ref) ->
        Map.get(manifest_ref, "bundle_fingerprint") || Map.get(manifest_ref, :bundle_fingerprint)

      true ->
        nil
    end
  end

  defp load_archived_bundle(fingerprint, runtime_context)
       when is_binary(fingerprint) and fingerprint != "" do
    case BundleArchive.load(fingerprint) do
      {:ok, bundle} ->
        runtime_context
        |> Map.put(:bundle_root, bundle.root_path)
        |> Map.put(:manifest_path, bundle.manifest_path)
        |> Map.put(:payloads_path, bundle.payloads_path)

      {:error, reason} ->
        Logger.warning("failed to materialize runtime bundle for remote agent",
          fingerprint: fingerprint,
          reason: inspect(reason)
        )

        runtime_context
    end
  end

  defp load_archived_bundle(_fingerprint, runtime_context), do: runtime_context

  defp put_allocation_environment(config, allocation) do
    allocation_env = ResourceSpec.allocation_env(allocation)

    Map.update(config, "environment", allocation_env, fn
      env when is_map(env) -> Map.merge(env, allocation_env)
      _env -> allocation_env
    end)
  end

  defp put_artifact_environment(config, artifact_refs) do
    artifact_env = %{"MN_ARTIFACTS_JSON" => Jason.encode!(artifact_refs || [])}

    Map.update(config, "environment", artifact_env, fn
      env when is_map(env) -> Map.merge(env, artifact_env)
      _env -> artifact_env
    end)
  end

  defp put_runtime_environment(config, runtime_env) when is_map(runtime_env) do
    runtime_env =
      runtime_env
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Map.new()

    Map.update(config, "environment", runtime_env, fn
      env when is_map(env) -> Map.merge(env, runtime_env)
      _env -> runtime_env
    end)
  end

  defp put_runtime_environment(config, _runtime_env), do: config

  defp heartbeat_interval_ms do
    Application.get_env(
      :mirror_neuron,
      :agent_heartbeat_interval_ms,
      @default_heartbeat_interval_ms
    )
  end

  defp schedule_heartbeat(%{heartbeat_interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    state = cancel_heartbeat_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:heartbeat, token}, interval_ms)
    %{state | heartbeat_timer_ref: timer_ref, heartbeat_token: token}
  end

  defp schedule_heartbeat(state), do: cancel_heartbeat_timer(state)

  defp cancel_heartbeat_timer(%{heartbeat_timer_ref: ref, heartbeat_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:heartbeat, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_heartbeat_timer(state)
  end

  defp cancel_heartbeat_timer(state), do: state

  defp clear_heartbeat_timer(state),
    do: %{state | heartbeat_timer_ref: nil, heartbeat_token: nil}

  defp build_message(state, incoming, to_node, message_type, payload, opts) do
    headers =
      incoming
      |> Message.headers()
      |> workflow_headers_for_target(state, incoming, to_node)
      |> Map.merge(Keyword.get(opts, :headers, %{}))
      |> with_attempt_epoch(state)

    Message.new(
      state.job_id,
      state.node.node_id,
      to_node,
      message_type,
      payload,
      class: Keyword.get(opts, :class, Message.class(incoming)),
      correlation_id: Keyword.get(opts, :correlation_id, Message.correlation_id(incoming)),
      causation_id: Keyword.get(opts, :causation_id, Message.id(incoming)),
      content_type: Keyword.get(opts, :content_type, Message.content_type(incoming)),
      content_encoding: Keyword.get(opts, :content_encoding, Message.content_encoding(incoming)),
      headers: headers,
      artifacts: Keyword.get(opts, :artifacts, Message.artifacts(incoming)),
      stream: Keyword.get(opts, :stream, Message.stream(incoming)),
      message_id:
        Keyword.get_lazy(opts, :message_id, fn ->
          deterministic_output_id(
            state,
            incoming,
            to_node,
            Keyword.get(opts, :delivery_key, message_type)
          )
        end)
    )
  end

  defp with_attempt_epoch(headers, state) when is_map(headers) do
    case state.runtime_context[:lease_epoch] do
      epoch when is_integer(epoch) -> Map.put(headers, "mn.attempt_epoch", epoch)
      _epoch -> headers
    end
  end

  defp deterministic_output_id(state, incoming, to_node, delivery_key) do
    [Message.id(incoming), state.node.node_id, to_node, to_string(delivery_key)]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp workflow_headers_for_target(headers, state, incoming, to_node) do
    agent_steps = Map.get(state.runtime_context, :workflow_agent_steps, %{})

    case Map.get(agent_steps, to_node) do
      nil ->
        headers

      step_id ->
        headers
        |> Map.drop([
          "mn.workflow.step_id",
          "mn.workflow.graph_revision",
          "mn.workflow.template_id",
          "mn.workflow.region_id",
          "mn.workflow.attempt_id",
          "mn.workflow.attempt",
          "mn.workflow.deadline_at",
          "mn.workflow.heartbeat_deadline_at",
          "mn.workflow.idempotency_key"
        ])
        |> Map.put("mn.workflow.run_id", Map.get(state.runtime_context, :workflow_run_id))
        |> Map.put("mn.workflow.step_id", step_id)
        |> Map.put("mn.workflow.source_step_id", workflow_step_id(incoming))
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    end
  end

  defp workflow_context(message, state) do
    headers = Message.headers(message)

    step_id =
      workflow_step_id(message) ||
        Map.get(state.runtime_context[:workflow_agent_steps] || %{}, state.node.node_id)

    %{
      "run_id" =>
        Map.get(headers, "mn.workflow.run_id") || Map.get(state.runtime_context, :workflow_run_id),
      "step_id" => step_id,
      "graph_revision" => Map.get(headers, "mn.workflow.graph_revision"),
      "template_id" => Map.get(headers, "mn.workflow.template_id"),
      "region_id" => Map.get(headers, "mn.workflow.region_id"),
      "attempt_id" => Map.get(headers, "mn.workflow.attempt_id"),
      "attempt" => Map.get(headers, "mn.workflow.attempt"),
      "deadline_at" => Map.get(headers, "mn.workflow.deadline_at"),
      "heartbeat_deadline_at" => Map.get(headers, "mn.workflow.heartbeat_deadline_at"),
      "idempotency_key" => Map.get(headers, "mn.workflow.idempotency_key")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp enrich_workflow_payload(payload, incoming) do
    workflow = workflow_context_from_headers(incoming)

    cond do
      map_size(workflow) == 0 ->
        payload

      is_map(payload) ->
        Map.merge(workflow, stringify_keys(payload))

      true ->
        workflow
    end
  end

  defp workflow_context_from_headers(message) do
    headers = Message.headers(message)

    %{
      "workflow_run_id" => Map.get(headers, "mn.workflow.run_id"),
      "step" => Map.get(headers, "mn.workflow.step_id"),
      "step_id" => Map.get(headers, "mn.workflow.step_id"),
      "graph_revision" => Map.get(headers, "mn.workflow.graph_revision"),
      "template_id" => Map.get(headers, "mn.workflow.template_id"),
      "region_id" => Map.get(headers, "mn.workflow.region_id"),
      "attempt_id" => Map.get(headers, "mn.workflow.attempt_id"),
      "attempt" => Map.get(headers, "mn.workflow.attempt"),
      "deadline_at" => Map.get(headers, "mn.workflow.deadline_at"),
      "heartbeat_deadline_at" => Map.get(headers, "mn.workflow.heartbeat_deadline_at"),
      "idempotency_key" => Map.get(headers, "mn.workflow.idempotency_key")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp workflow_step_id(message) do
    message
    |> Message.headers()
    |> Map.get("mn.workflow.step_id")
  end

  defp target_backpressure_opts(state, to_node) do
    state.runtime_context
    |> Map.get(:backpressure_by_agent, %{})
    |> Map.get(to_node, [])
  end

  defp recovery_flag?(snapshot, string_key, atom_key) when is_map(snapshot) do
    Map.get(snapshot, string_key, Map.get(snapshot, atom_key, false)) == true
  end

  defp recovery_flag?(_snapshot, _string_key, _atom_key), do: false
end
