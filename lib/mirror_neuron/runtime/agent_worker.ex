defmodule MirrorNeuron.Runtime.AgentWorker do
  use GenServer
  require Logger

  alias MirrorNeuron.AgentRegistry
  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Backpressure
  alias MirrorNeuron.Runtime.Naming
  alias MirrorNeuron.Runtime.RouteCondition

  @default_heartbeat_interval_ms 30_000
  @default_pending_drain_batch_size 25
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
          recovered_snapshot: recovery_snapshot,
          checkpoint_metadata: custom_checkpoint_metadata(recovery_snapshot),
          pressure_snapshot: nil
        }

        schedule_heartbeat(state.heartbeat_interval_ms)
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

    {:noreply, drain_pending(recovered_state)}
  end

  @impl true
  def handle_cast(:pause, state) do
    next_state = %{state | paused?: true}
    persist_snapshot(next_state)
    {:noreply, next_state}
  end

  def handle_cast(:resume, state) do
    next_state = %{state | paused?: false}
    persist_snapshot(next_state)
    {:noreply, drain_pending(next_state)}
  end

  def handle_cast(:cancel, state), do: {:stop, :normal, state}

  def handle_cast({:deliver, message}, %{paused?: true} = state) do
    case enqueue_pending(message, state) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, next_state} ->
        {:noreply, next_state}
    end
  end

  def handle_cast({:deliver, message}, state) do
    normalized = Message.normalize!(message, job_id: state.job_id, to: state.node.node_id)
    {:noreply, process_message(normalized, state)}
  end

  @impl true
  def handle_call(:pressure_snapshot, _from, state) do
    snapshot = pressure_snapshot(state)
    {:reply, snapshot, %{state | pressure_snapshot: snapshot}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    persist_snapshot(state)
    schedule_heartbeat(state.heartbeat_interval_ms)
    {:noreply, state}
  end

  def handle_info(:drain_pending, state) do
    {:noreply, drain_pending(state)}
  end

  def handle_info({:mirror_neuron_scheduled_message, message}, state) do
    handle_cast({:deliver, message}, state)
  end

  defp drain_pending(%{paused?: true} = state), do: state

  defp drain_pending(state) do
    drain_pending(state, pending_drain_batch_size())
  end

  defp drain_pending(state, 0) do
    if :queue.is_empty(state.pending) do
      persist_snapshot(state)
    else
      Process.send_after(self(), :drain_pending, 0)
    end

    state
  end

  defp drain_pending(state, remaining_count) do
    case :queue.out(state.pending) do
      {{:value, message}, remaining_queue} ->
        drained_state =
          state
          |> Map.put(:pending, remaining_queue)
          |> Map.put(:mailbox_depth, max(state.mailbox_depth - 1, 0))

        drained_state = process_message(message, drained_state)

        drain_pending(drained_state, remaining_count - 1)

      {:empty, _queue} ->
        persist_snapshot(state)
        state
    end
  end

  defp process_message(message, state) do
    state = %{state | inflight_message: message}
    persist_snapshot(state)

    context = %{
      job_id: state.job_id,
      node: state.node,
      coordinator: state.coordinator,
      outbound_edges: state.outbound_edges,
      inbound_edges: state.inbound_edges,
      bundle_root: state.runtime_context[:bundle_root],
      manifest_path: state.runtime_context[:manifest_path],
      payloads_path: state.runtime_context[:payloads_path],
      template_type: Map.get(state.node, :type, "generic"),
      invocation: state.processed_messages + 1
    }

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

        Enum.each(actions, &execute_action(&1, message, next_state))
        persist_snapshot(next_state)
        next_state

      {:error, reason, new_local_state} ->
        failed_state = %{state | local_state: new_local_state, inflight_message: nil}
        persist_snapshot(failed_state)
        send(state.coordinator, {:agent_failed, state.node.node_id, reason})
        failed_state
    end
  end

  defp execute_action({:emit, message_type, payload}, incoming, state) do
    execute_action({:emit, message_type, payload, []}, incoming, state)
  end

  defp execute_action({:emit, message_type, payload, opts}, incoming, state) do
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

    Enum.each(selected_edges, fn edge ->
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

      result =
        Runtime.deliver(
          state.job_id,
          edge.to_node,
          build_message(state, incoming, edge.to_node, message_type, payload, opts),
          target_backpressure_opts(state, edge.to_node)
        )

      maybe_report_delivery_pressure(result, edge.to_node, message_type, state)
    end)
  end

  defp execute_action({:emit_to, to_node, message_type, payload}, incoming, state) do
    execute_action({:emit_to, to_node, message_type, payload, []}, incoming, state)
  end

  defp execute_action({:emit_to, to_node, message_type, payload, opts}, incoming, state) do
    result =
      Runtime.deliver(
        state.job_id,
        to_node,
        build_message(state, incoming, to_node, message_type, payload, opts),
        target_backpressure_opts(state, to_node)
      )

    maybe_report_delivery_pressure(result, to_node, message_type, state)
  end

  defp execute_action({:emit_message, message}, _incoming, state) do
    normalized = Message.normalize!(message, job_id: state.job_id, from: state.node.node_id)
    to_node = Message.to(normalized)

    result =
      Runtime.deliver(state.job_id, to_node, normalized, target_backpressure_opts(state, to_node))

    maybe_report_delivery_pressure(
      result,
      to_node,
      Message.type(normalized),
      state
    )
  end

  defp execute_action({:event, event_type, payload}, _incoming, state) do
    send(state.coordinator, {:agent_event, state.node.node_id, event_type, payload})
  end

  defp execute_action({:checkpoint, snapshot}, _incoming, state) do
    send(state.coordinator, {:agent_checkpoint, state.node.node_id, snapshot})
  end

  defp execute_action({:complete_job, result}, _incoming, state) do
    if agent_completion_writes_terminal_job?(state) do
      persist_terminal_completion(state, result)
    end

    send(state.coordinator, {:agent_completed_job, state.node.node_id, result})
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

    pressure = pressure_snapshot(state)

    metadata =
      Map.merge(state.checkpoint_metadata, %{
        "paused" => state.paused?,
        "outbound_edges" => Enum.map(state.outbound_edges, & &1.to_node),
        "heartbeat_interval_ms" => state.heartbeat_interval_ms,
        "recovery_state" => encoded_state,
        "backpressure" => pressure,
        "pending_messages_truncated" => pending_messages_truncated?(state),
        "pending_message_count" => state.mailbox_depth,
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
      mailbox_depth: state.mailbox_depth,
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

  defp enqueue_pending(message, state) do
    normalized = Message.normalize!(message, job_id: state.job_id, to: state.node.node_id)
    next_depth = state.mailbox_depth + 1
    pressure = pressure_snapshot(state, next_depth)

    if Backpressure.saturated?(pressure) do
      report_local_backpressure(normalized, pressure, state)
      persist_snapshot(%{state | pressure_snapshot: pressure})
      {:error, %{state | pressure_snapshot: pressure}}
    else
      queued = :queue.in(normalized, state.pending)

      next_state = %{
        state
        | pending: queued,
          mailbox_depth: next_depth,
          pressure_snapshot: pressure
      }

      persist_snapshot(next_state)
      {:ok, next_state}
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

  defp report_local_backpressure(message, pressure, state) do
    payload =
      Backpressure.retry_later_reason(pressure, %{
        "from" => Message.from(message),
        "to" => state.node.node_id,
        "message_type" => Message.type(message),
        "dropped" => true
      })

    send(state.coordinator, {:agent_event, state.node.node_id, :backpressure_rejected, payload})
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
    runtime_config =
      node.config
      |> Map.put("__bundle_root", runtime_context[:bundle_root])
      |> Map.put("__manifest_path", runtime_context[:manifest_path])
      |> Map.put("__payloads_path", runtime_context[:payloads_path])

    %{node | config: runtime_config}
  end

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
        template_type: Map.get(state.node, :type, "generic")
      }

      case state.module.recover(state.local_state, context) do
        {:ok, new_local_state, actions} ->
          next_state = %{state | local_state: new_local_state, recovered_snapshot: nil}
          recovery_message = build_recovery_message(next_state)
          Enum.each(actions, &execute_action(&1, recovery_message, next_state))
          persist_snapshot(next_state)
          {:ok, next_state}

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

  defp pending_drain_batch_size do
    config_integer(
      "MN_AGENT_PENDING_DRAIN_BATCH_SIZE",
      :agent_pending_drain_batch_size,
      @default_pending_drain_batch_size
    )
    |> max(1)
  end

  defp schedule_heartbeat(interval_ms) do
    Process.send_after(self(), :heartbeat, interval_ms)
  end

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
      {:ok, :erlang.binary_to_term(binary)}
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
      headers: Map.merge(Message.headers(incoming), Keyword.get(opts, :headers, %{})),
      artifacts: Keyword.get(opts, :artifacts, Message.artifacts(incoming)),
      stream: Keyword.get(opts, :stream, Message.stream(incoming))
    )
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
