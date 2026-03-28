defmodule MirrorNeuron.Runtime.AgentWorker do
  use GenServer
  require Logger

  alias MirrorNeuron.AgentRegistry
  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.Naming

  def child_spec({job_id, node, edges, coordinator, runtime_context}) do
    %{
      id: {:agent_worker, job_id, node.node_id},
      start: {__MODULE__, :start_link, [{job_id, node, edges, coordinator, runtime_context}]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link({job_id, node, edges, coordinator, runtime_context}) do
    GenServer.start_link(__MODULE__, {job_id, node, edges, coordinator, runtime_context},
      name: Naming.via_agent(job_id, node.node_id)
    )
  end

  @impl true
  def init({job_id, node, edges, coordinator, runtime_context}) do
    module = AgentRegistry.fetch!(node.agent_type)
    outbound_edges = Enum.filter(edges, &(&1.from_node == node.node_id))
    inbound_edges = Enum.filter(edges, &(&1.to_node == node.node_id))

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
          paused?: false,
          pending: :queue.new(),
          mailbox_depth: 0,
          processed_messages: 0
        }

        persist_snapshot(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
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
    context = %{
      job_id: state.job_id,
      node: state.node,
      coordinator: state.coordinator,
      outbound_edges: state.outbound_edges,
      inbound_edges: state.inbound_edges,
      bundle_root: state.runtime_context[:bundle_root],
      manifest_path: state.runtime_context[:manifest_path],
      payloads_path: state.runtime_context[:payloads_path]
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
            processed_messages: state.processed_messages + 1
        }

        Enum.each(actions, &execute_action(&1, message, next_state))
        persist_snapshot(next_state)
        next_state

      {:error, reason, new_local_state} ->
        failed_state = %{state | local_state: new_local_state}
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
    snapshot = %{
      agent_id: state.node.node_id,
      node_id: state.node.node_id,
      agent_type: state.node.agent_type,
      role: state.node.role,
      current_state: stringify_local_state(state.local_state),
      mailbox_depth: state.mailbox_depth,
      processed_messages: state.processed_messages,
      assigned_node: to_string(Node.self()),
      parent_job_id: state.job_id,
      metadata: %{
        paused: state.paused?,
        outbound_edges: Enum.map(state.outbound_edges, & &1.to_node)
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
