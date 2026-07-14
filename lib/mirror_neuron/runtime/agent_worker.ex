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
  alias MirrorNeuron.Runtime.Naming
  alias MirrorNeuron.Runtime.RouteCondition
  alias MirrorNeuron.Scheduler

  @default_heartbeat_interval_ms 30_000
  @default_snapshot_pending_limit 100
  @runtime_metadata_keys [
    "paused",
    "outbound_edges",
    "heartbeat_interval_ms",
    "recovery_state",
    "backpressure",
    "pending_messages_truncated",
    "pending_message_count",
    "lease_epoch",
    "lease_owner",
    "execution_profile"
  ]

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
    recovery_snapshot = recovery_snapshot || load_recovery_snapshot(job_id, node.node_id)
    module = AgentRegistry.fetch!(node.agent_type)

    runtime_context = materialize_runtime_bundle_context(runtime_context)
    node = inject_runtime_paths(node, runtime_context)

    case initialize_local_state(module, node, recovery_snapshot) do
      {:ok, local_state} ->
        pending_messages = recovered_replay_messages(recovery_snapshot)

        state = %{
          job_id: job_id,
          node: node,
          module: module,
          local_state: local_state,
          outbound_edges: outbound_edges,
          inbound_edges: inbound_edges,
          runtime_context: runtime_context,
          coordinator: coordinator,
          paused?: recovered_paused?(recovery_snapshot),
          pending: :queue.from_list(pending_messages),
          mailbox_depth: length(pending_messages),
          processed_messages: recovered_processed_messages(recovery_snapshot),
          inflight_message: nil,
          heartbeat_interval_ms: heartbeat_interval_ms(),
          heartbeat_timer_ref: nil,
          heartbeat_token: nil,
          delivery_consumer: Delivery.consumer_id(job_id, node.node_id),
          delivery_timer_ref: nil,
          delivery_token: nil,
          reclaim_deliveries?: not is_nil(recovery_snapshot),
          recovered_snapshot: recovery_snapshot,
          checkpoint_metadata: custom_checkpoint_metadata(recovery_snapshot),
          pressure_snapshot: nil
        }

        state = schedule_heartbeat(state)
        persist_snapshot(state)
        {:ok, state, {:continue, :recover}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    recovered_state =
      case maybe_recover_actions(state) do
        {:ok, next_state} ->
          next_state

        {:error, reason, next_state} ->
          send(state.coordinator, {:agent_failed, state.node.node_id, reason})
          next_state
      end

    case requeue_recovered_messages(recovered_state) do
      {:ok, next_state} -> {:noreply, schedule_delivery_poll(next_state, 0)}
      {:error, reason, next_state} -> {:stop, reason, next_state}
    end
  end

  @impl true
  def handle_cast(:pause, state) do
    next_state =
      state
      |> cancel_delivery_timer()
      |> Map.put(:paused?, true)

    persist_snapshot(next_state)
    {:noreply, next_state}
  end

  def handle_cast(:resume, state) do
    next_state = %{state | paused?: false}
    persist_snapshot(next_state)
    {:noreply, schedule_delivery_poll(next_state, 0)}
  end

  def handle_cast(:cancel, state), do: {:stop, :normal, state}

  def handle_cast({:deliver, message}, state) do
    _result = Runtime.deliver(state.job_id, state.node.node_id, message)
    {:noreply, state}
  end

  def handle_cast(:delivery_available, %{paused?: true} = state) do
    persist_snapshot(state)
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
    persist_snapshot(state)
    {:noreply, schedule_heartbeat(state)}
  end

  def handle_info({:heartbeat, _stale_token}, state), do: {:noreply, state}

  def handle_info(:heartbeat, state) do
    persist_snapshot(state)
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

  defp requeue_recovered_messages(state) do
    state.pending
    |> :queue.to_list()
    |> Enum.reduce_while(:ok, fn message, :ok ->
      case Delivery.recover(state.job_id, state.node.node_id, message) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok ->
        {:ok, %{state | pending: :queue.new(), mailbox_depth: 0, inflight_message: nil}}

      {:error, reason} ->
        {:error, {:failed_to_requeue_recovered_messages, reason}, state}
    end
  end

  defp poll_deliveries(state) do
    case Delivery.read(
           state.job_id,
           state.node.node_id,
           state.delivery_consumer,
           reclaim: state.reclaim_deliveries?
         ) do
      {:ok, []} ->
        state
        |> Map.put(:reclaim_deliveries?, false)
        |> schedule_delivery_poll(Delivery.poll_ms())

      {:ok, [delivery | _rest]} ->
        state = %{state | reclaim_deliveries?: false}

        delivery
        |> process_delivery(state)
        |> schedule_delivery_poll(0)

      {:error, reason} ->
        Logger.warning("failed to poll durable message deliveries",
          job_id: state.job_id,
          agent_id: state.node.node_id,
          reason: inspect(reason)
        )

        schedule_delivery_poll(state, Delivery.poll_ms())
    end
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
        case Delivery.ack(
               state.job_id,
               state.node.node_id,
               state.delivery_consumer,
               delivery
             ) do
          :ok ->
            persist_snapshot(next_state)

            send(state.coordinator, {
              :agent_event,
              state.node.node_id,
              :message_acked,
              %{"message_id" => delivery.message_id, "attempt" => delivery.attempt}
            })

          {:error, reason} ->
            report_delivery_retry(delivery, {:ack_failed, reason}, state)
        end

        next_state

      {:error, reason, next_state} ->
        report_delivery_retry(delivery, reason, state)
        send(state.coordinator, {:agent_failed, state.node.node_id, reason})
        next_state
    end
  end

  defp report_delivery_retry(delivery, reason, state) do
    _result =
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
        "reason" => inspect(reason)
      }
    })
  end

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
    persist_snapshot(state)

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
      workflow: workflow
    }

    if map_size(workflow) > 0 do
      send(state.coordinator, {:workflow_message_received, state.node.node_id, message})
    end

    send(
      state.coordinator,
      {:agent_event, state.node.node_id, :agent_message_received, Message.summary(message)}
    )

    case state.module.handle_message(message, state.local_state, context) do
      {:ok, new_local_state, actions} ->
        next_state =
          %{
            state
            | local_state: new_local_state,
              processed_messages: state.processed_messages + 1,
              inflight_message: nil
          }
          |> merge_checkpoint_metadata(actions)

        case execute_actions(actions, message, next_state) do
          :ok ->
            persist_snapshot(next_state)

            if map_size(workflow) > 0 do
              send(state.coordinator, {:workflow_message_acked, state.node.node_id, message})
            end

            {:ok, next_state}

          {:error, reason} ->
            failed_state = %{state | inflight_message: message}
            persist_snapshot(failed_state)
            {:error, {:output_delivery_failed, reason}, failed_state}
        end

      {:error, reason, new_local_state} ->
        failed_state = %{state | local_state: new_local_state, inflight_message: message}
        persist_snapshot(failed_state)
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
    normalized = put_in(normalized, ["envelope", "message_id"], message_id)

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

  defp execute_action({:event, event_type, payload}, incoming, state, _action_index) do
    send(
      state.coordinator,
      {:agent_event, state.node.node_id, event_type, enrich_workflow_payload(payload, incoming)}
    )

    :ok
  end

  defp execute_action({:checkpoint, snapshot}, _incoming, state, _action_index) do
    send(state.coordinator, {:agent_checkpoint, state.node.node_id, snapshot})
    :ok
  end

  defp execute_action({:complete_step, result}, incoming, state, _action_index) do
    send(
      state.coordinator,
      {:agent_event, state.node.node_id, :workflow_step_attempt_completed,
       enrich_workflow_payload(result, incoming)}
    )

    :ok
  end

  defp execute_action({:complete_run, result}, _incoming, state, _action_index) do
    send(state.coordinator, {:agent_completed_run, state.node.node_id, result})

    if agent_completion_writes_terminal_job?(state) and not coordinator_alive?(state.coordinator) do
      persist_terminal_completion(state, result)
    end

    :ok
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

  defp persist_snapshot(state) do
    inspected_state = inspected_local_state(state.module, state.local_state)
    encoded_state = encoded_local_state(state.module, state.local_state)
    durable_depth = durable_delivery_depth(state)

    pressure = pressure_snapshot(state, durable_depth)

    metadata =
      Map.merge(state.checkpoint_metadata, %{
        "paused" => state.paused?,
        "outbound_edges" => Enum.map(state.outbound_edges, & &1.to_node),
        "heartbeat_interval_ms" => state.heartbeat_interval_ms,
        "recovery_state" => encoded_state,
        "backpressure" => pressure,
        "pending_messages_truncated" => pending_messages_truncated?(state),
        "pending_message_count" => durable_depth,
        "lease_epoch" => state.runtime_context[:lease_epoch],
        "lease_owner" => state.runtime_context[:lease_owner],
        "execution_profile" =>
          get_in(state.runtime_context, [:execution_profiles, state.node.node_id]) ||
            get_in(state.node, [:config, "execution_profile"])
      })

    snapshot = %{
      agent_id: state.node.node_id,
      node_id: state.node.node_id,
      agent_type: state.node.agent_type,
      type: Map.get(state.node, :type, "generic"),
      role: state.node.role,
      current_state: inspected_state,
      mailbox_depth: durable_depth,
      processed_messages: state.processed_messages,
      assigned_node: to_string(Node.self()),
      inflight_message: state.inflight_message,
      pending_messages: pending_messages_for_snapshot(state),
      last_heartbeat_at: Runtime.timestamp(),
      parent_job_id: state.job_id,
      metadata: metadata
    }

    case RedisStore.persist_agent(state.job_id, state.node.node_id, snapshot) do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to persist agent snapshot for #{state.job_id}/#{state.node.node_id}: #{inspect(reason)}"
        )
    end

    send(state.coordinator, {:agent_pressure, state.node.node_id, pressure})
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

  defp merge_checkpoint_metadata(state, actions) do
    metadata =
      Enum.reduce(actions, %{}, fn
        {:checkpoint, snapshot}, acc when is_map(snapshot) ->
          Map.merge(acc, custom_checkpoint_metadata(snapshot))

        _action, acc ->
          acc
      end)

    if map_size(metadata) == 0 do
      state
    else
      %{state | checkpoint_metadata: Map.merge(state.checkpoint_metadata, metadata)}
    end
  end

  defp custom_checkpoint_metadata(%{"metadata" => metadata}) when is_map(metadata) do
    metadata
    |> stringify_keys()
    |> Map.drop(@runtime_metadata_keys)
  end

  defp custom_checkpoint_metadata(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> stringify_keys()
    |> Map.drop(@runtime_metadata_keys)
  end

  defp custom_checkpoint_metadata(_snapshot), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp persist_terminal_completion(state, result) do
    updates = %{
      "status" => "completed",
      "result" => %{"agent_id" => state.node.node_id, "output" => result}
    }

    persist_terminal_job(state, updates)
  end

  defp agent_completion_writes_terminal_job?(state) do
    Map.get(state.runtime_context, :job_type, "batch") == "batch"
  end

  defp coordinator_alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)

  defp coordinator_alive?(pid) when is_pid(pid) do
    case :rpc.call(node(pid), Process, :alive?, [pid], 5_000) do
      true -> true
      _ -> false
    end
  end

  defp coordinator_alive?(_pid), do: false

  defp persist_terminal_job(state, updates) do
    defaults =
      %{
        "graph_id" => state.runtime_context[:graph_id],
        "job_name" => state.runtime_context[:job_name],
        "root_agent_ids" => state.runtime_context[:entrypoints] || [],
        "placement_policy" => state.runtime_context[:placement_policy] || "local",
        "recovery_policy" => state.runtime_context[:recovery_policy] || "local_restart",
        "manifest" => state.runtime_context[:manifest],
        "manifest_ref" => manifest_ref(state),
        "submitted_at" => state.runtime_context[:submitted_at] || Runtime.timestamp()
      }
      |> maybe_put_lease(state)

    case RedisStore.persist_terminal_job(state.job_id, updates, defaults) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to persist terminal job state for #{state.job_id}/#{state.node.node_id}: #{inspect(reason)}"
        )
    end
  end

  defp manifest_ref(state) do
    state.runtime_context[:manifest_ref] ||
      %{
        "graph_id" => state.runtime_context[:graph_id],
        "manifest_version" => state.runtime_context[:manifest_version],
        "manifest_path" => state.runtime_context[:manifest_path],
        "job_path" => state.runtime_context[:bundle_root]
      }
  end

  defp maybe_put_lease(map, state) do
    case state.runtime_context[:lease_epoch] do
      nil ->
        map

      epoch ->
        map
        |> Map.put("lease_epoch", epoch)
        |> Map.put("lease_owner", state.runtime_context[:lease_owner])
        |> Map.put("lease", %{
          "epoch" => epoch,
          "owner_id" => state.runtime_context[:lease_owner]
        })
    end
  end

  defp stringify_local_state(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_local_state(value)}
    end)
  end

  defp stringify_local_state(list) when is_list(list),
    do: Enum.map(list, &stringify_local_state/1)

  defp stringify_local_state(value), do: value

  defp initialize_local_state(module, node, %{"metadata" => metadata})
       when is_map(metadata) do
    case Map.fetch(metadata, "recovery_state") do
      {:ok, encoded} when is_binary(encoded) ->
        case decode_local_state(encoded) do
          {:ok, local_state} ->
            restore_local_state(module, local_state)

          :error ->
            {:error, "corrupt recovery_state checkpoint"}
        end

      _ ->
        module.init(node)
    end
  end

  defp initialize_local_state(module, node, _snapshot), do: module.init(node)

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

  defp maybe_recover_actions(%{recovered_snapshot: nil} = state), do: {:ok, state}

  defp maybe_recover_actions(state) do
    if function_exported?(state.module, :recover, 2) do
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
        template_type: Map.get(state.node, :type, "generic")
      }

      case state.module.recover(state.local_state, context) do
        {:ok, new_local_state, actions} ->
          next_state = %{state | local_state: new_local_state, recovered_snapshot: nil}
          recovery_message = build_recovery_message(next_state)

          case execute_actions(actions, recovery_message, next_state) do
            :ok ->
              persist_snapshot(next_state)
              {:ok, next_state}

            {:error, reason} ->
              {:error, {:recovery_output_delivery_failed, reason}, next_state}
          end

        {:error, reason, new_local_state} ->
          {:error, reason, %{state | local_state: new_local_state, recovered_snapshot: nil}}
      end
    else
      {:ok, %{state | recovered_snapshot: nil}}
    end
  end

  defp load_recovery_snapshot(job_id, agent_id) do
    case RedisStore.fetch_agent(job_id, agent_id) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  end

  defp recovered_replay_messages(snapshot) do
    [Map.get(snapshot || %{}, "inflight_message")]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(Map.get(snapshot || %{}, "pending_messages", []))
  end

  defp recovered_processed_messages(%{"processed_messages" => count}) when is_integer(count),
    do: count

  defp recovered_processed_messages(_snapshot), do: 0

  defp recovered_paused?(%{"metadata" => %{"paused" => paused}}), do: paused == true
  defp recovered_paused?(_snapshot), do: false

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

  defp pending_messages_for_snapshot(state) do
    state.pending
    |> :queue.to_list()
    |> Enum.take(snapshot_pending_limit(state))
  end

  defp pending_messages_truncated?(state) do
    state.mailbox_depth > snapshot_pending_limit(state)
  end

  defp snapshot_pending_limit(state) do
    configured =
      config_integer(
        "MN_AGENT_SNAPSHOT_PENDING_LIMIT",
        :agent_snapshot_pending_limit,
        @default_snapshot_pending_limit
      )
      |> max(1)

    max(configured, Backpressure.config(state.node).max_queue_depth)
  end

  defp encode_local_state(local_state) do
    local_state
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  defp encoded_local_state(module, local_state) do
    module.snapshot_state(local_state)
    |> encode_local_state()
  end

  defp decode_local_state(nil), do: :error

  defp decode_local_state(encoded) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp build_recovery_message(state) do
    Message.new(
      state.job_id,
      state.node.node_id,
      state.node.node_id,
      "recovery",
      %{},
      class: "control",
      correlation_id: unique_id()
    )
  end

  defp inspected_local_state(module, local_state) do
    local_state
    |> module.inspect_state()
    |> stringify_local_state()
  end

  defp restore_local_state(module, snapshot) do
    module.restore_state(snapshot)
  rescue
    error -> {:error, error}
  end

  defp unique_id do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp build_message(state, incoming, to_node, message_type, payload, opts) do
    headers =
      incoming
      |> Message.headers()
      |> workflow_headers_for_target(state, incoming, to_node)
      |> Map.merge(Keyword.get(opts, :headers, %{}))

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

  defp config_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil ->
        Application.get_env(:mirror_neuron, key, default)

      "" ->
        Application.get_env(:mirror_neuron, key, default)

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end
end
