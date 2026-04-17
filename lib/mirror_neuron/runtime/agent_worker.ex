defmodule MirrorNeuron.Runtime.AgentWorker do
  use GenServer
  require Logger

  alias MirrorNeuron.AgentRegistry
  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Naming

  @default_heartbeat_interval_ms 2_000

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
          recovered_snapshot: recovery_snapshot
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
          persist_terminal_failure(next_state, reason)
          send(state.coordinator, {:agent_failed, state.node.node_id, reason})
          next_state
      end

    {:noreply, drain_pending(recovered_state)}
  end

  @impl true
  def handle_cast(:pause, state), do: {:noreply, %{state | paused?: true}}

  def handle_cast(:resume, state) do
    next_state = %{state | paused?: false}
    {:noreply, drain_pending(next_state)}
  end

  def handle_cast(:cancel, state), do: {:stop, :normal, state}

  def handle_cast({:deliver, message}, %{paused?: true} = state) do
    queued =
      :queue.in(
        Message.normalize!(message, job_id: state.job_id, to: state.node.node_id),
        state.pending
      )

    next_state = %{state | pending: queued, mailbox_depth: state.mailbox_depth + 1}
    persist_snapshot(next_state)
    {:noreply, next_state}
  end

  def handle_cast({:deliver, message}, state) do
    normalized = Message.normalize!(message, job_id: state.job_id, to: state.node.node_id)
    {:noreply, process_message(normalized, state)}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    persist_snapshot(state)
    schedule_heartbeat(state.heartbeat_interval_ms)
    {:noreply, state}
  end

  defp drain_pending(%{paused?: true} = state), do: state

  defp drain_pending(state) do
    case :queue.out(state.pending) do
      {{:value, message}, remaining} ->
        drained_state =
          state
          |> Map.put(:pending, remaining)
          |> Map.put(:mailbox_depth, max(state.mailbox_depth - 1, 0))

        drained_state = process_message(message, drained_state)

        drain_pending(drained_state)

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
        next_state = %{
          state
          | local_state: new_local_state,
            processed_messages: state.processed_messages + 1,
            inflight_message: nil
        }

        Enum.each(actions, &execute_action(&1, message, next_state))
        persist_snapshot(next_state)
        next_state

      {:error, reason, new_local_state} ->
        failed_state = %{state | local_state: new_local_state, inflight_message: nil}
        persist_snapshot(failed_state)
        persist_terminal_failure(failed_state, reason)
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

    Enum.each(matching_edges, fn edge ->
      Runtime.deliver(
        state.job_id,
        edge.to_node,
        build_message(state, incoming, edge.to_node, message_type, payload, opts)
      )
    end)
  end

  defp execute_action({:emit_to, to_node, message_type, payload}, incoming, state) do
    execute_action({:emit_to, to_node, message_type, payload, []}, incoming, state)
  end

  defp execute_action({:emit_to, to_node, message_type, payload, opts}, incoming, state) do
    Runtime.deliver(
      state.job_id,
      to_node,
      build_message(state, incoming, to_node, message_type, payload, opts)
    )
  end

  defp execute_action({:emit_message, message}, _incoming, state) do
    normalized = Message.normalize!(message, job_id: state.job_id, from: state.node.node_id)
    Runtime.deliver(state.job_id, Message.to(normalized), normalized)
  end

  defp execute_action({:event, event_type, payload}, _incoming, state) do
    send(state.coordinator, {:agent_event, state.node.node_id, event_type, payload})
  end

  defp execute_action({:checkpoint, snapshot}, _incoming, state) do
    send(state.coordinator, {:agent_checkpoint, state.node.node_id, snapshot})
  end

  defp execute_action({:complete_job, result}, _incoming, state) do
    persist_terminal_completion(state, result)
    send(state.coordinator, {:agent_completed_job, state.node.node_id, result})
  end

  defp persist_snapshot(state) do
    inspected_state = inspected_local_state(state.module, state.local_state)
    encoded_state = encoded_local_state(state.module, state.local_state)

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
      pending_messages: :queue.to_list(state.pending),
      last_heartbeat_at: Runtime.timestamp(),
      parent_job_id: state.job_id,
      metadata: %{
        paused: state.paused?,
        outbound_edges: Enum.map(state.outbound_edges, & &1.to_node),
        heartbeat_interval_ms: state.heartbeat_interval_ms,
        recovery_state: encoded_state
      }
    }

    case RedisStore.persist_agent(state.job_id, state.node.node_id, snapshot) do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to persist agent snapshot for #{state.job_id}/#{state.node.node_id}: #{inspect(reason)}"
        )
    end

    send(state.coordinator, {:agent_checkpoint, state.node.node_id, snapshot})
  end

  defp persist_terminal_completion(state, result) do
    updates = %{
      "status" => "completed",
      "result" => %{"agent_id" => state.node.node_id, "output" => result}
    }

    persist_terminal_job(state, updates)
  end

  defp persist_terminal_failure(state, reason) do
    updates = %{
      "status" => "failed",
      "result" => %{"agent_id" => state.node.node_id, "error" => inspect(reason)}
    }

    persist_terminal_job(state, updates)
  end

  defp persist_terminal_job(state, updates) do
    defaults = %{
      "graph_id" => state.runtime_context[:graph_id],
      "job_name" => state.runtime_context[:job_name],
      "root_agent_ids" => state.runtime_context[:entrypoints] || [],
      "placement_policy" => state.runtime_context[:placement_policy] || "local",
      "recovery_policy" => state.runtime_context[:recovery_policy] || "local_restart",
      "manifest_ref" => %{
        "graph_id" => state.runtime_context[:graph_id],
        "manifest_version" => state.runtime_context[:manifest_version],
        "manifest_path" => state.runtime_context[:manifest_path],
        "job_path" => state.runtime_context[:bundle_root]
      },
      "submitted_at" => state.runtime_context[:submitted_at] || Runtime.timestamp()
    }

    case RedisStore.persist_terminal_job(state.job_id, updates, defaults) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to persist terminal job state for #{state.job_id}/#{state.node.node_id}: #{inspect(reason)}"
        )
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
    case decode_local_state(Map.get(metadata, "recovery_state")) do
      {:ok, local_state} ->
        restore_local_state(module, local_state)

      :error ->
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

  defp schedule_heartbeat(interval_ms) do
    Process.send_after(self(), :heartbeat, interval_ms)
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
end
