defmodule MirrorNeuron.Cluster.NodeMonitor do
  use GenServer
  require Logger

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.EventBus

  @default_reconnect_attempts 3
  @default_reconnect_backoff_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :monitor_nodes, true) do
      :net_kernel.monitor_nodes(true)
      node_state(opts).advertise_self("healthy", %{"self" => true})
    end

    {:ok,
     %{
       reconnecting: %{},
       connect: Keyword.get(opts, :connect, &Node.connect/1),
       lease_manager_module:
         Keyword.get(opts, :lease_manager_module, MirrorNeuron.Execution.LeaseManager),
       lease_manager_server:
         Keyword.get(opts, :lease_manager_server, MirrorNeuron.Execution.LeaseManager),
       leader: Keyword.get(opts, :leader, MirrorNeuron.Cluster.Leader),
       node_state: node_state(opts),
       reconciler: Keyword.get(opts, :reconciler, Reconciler),
       redis_store: Keyword.get(opts, :redis_store, RedisStore),
       event_bus: Keyword.get(opts, :event_bus, EventBus),
       reconnect_attempts:
         Keyword.get(opts, :reconnect_attempts) ||
           config_positive_integer(
             "MN_NODE_RECONNECT_ATTEMPTS",
             :node_reconnect_attempts,
             @default_reconnect_attempts
           ),
       reconnect_backoff_ms:
         Keyword.get(opts, :reconnect_backoff_ms) ||
           config_positive_integer(
             "MN_NODE_RECONNECT_BACKOFF_MS",
             :node_reconnect_backoff_ms,
             @default_reconnect_backoff_ms
           )
     }}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.notice("Node joined cluster: #{node}")

    state =
      node
      |> node_name()
      |> cancel_reconnect(state)

    restore_executor_capacity(state)
    state.node_state.mark(node, "healthy")
    Logger.notice("Node reconnected: #{node}")
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.notice("Node left cluster: #{node}")
    state.node_state.mark(node, "reconnecting")
    {:noreply, schedule_reconnect(node, 1, state)}
  end

  def handle_info({:reconnect_node, node, attempt}, state) do
    name = node_name(node)

    case Map.get(state.reconnecting, name) do
      %{attempt: ^attempt} ->
        reconnect_node(node, attempt, state)

      _stale_or_cancelled ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp reconnect_node(node, attempt, state) do
    if state.connect.(node) do
      Logger.notice("Node reconnected after #{attempt} attempt(s): #{node}")
      restore_executor_capacity(state)
      state.node_state.mark(node, "healthy")
      {:noreply, cancel_reconnect(node_name(node), state)}
    else
      if attempt >= state.reconnect_attempts do
        {:noreply, exhaust_reconnect(node, state)}
      else
        {:noreply, schedule_reconnect(node, attempt + 1, state)}
      end
    end
  end

  defp exhaust_reconnect(node, state) do
    reason = "node reconnect failed after #{state.reconnect_attempts} attempts"

    Logger.warning("#{reason}: #{node}")
    release_executor_capacity(node, state)
    reconcile_node(node, reason, state)
    state.node_state.mark(node, "offline")
    state.leader.node_down(node)
    cancel_reconnect(node_name(node), state)
  end

  defp schedule_reconnect(node, attempt, state) do
    name = node_name(node)
    state = cancel_reconnect(name, state)
    delay = reconnect_delay(attempt, state.reconnect_backoff_ms)
    timer_ref = Process.send_after(self(), {:reconnect_node, node, attempt}, delay)

    put_in(state.reconnecting[name], %{
      node: node,
      attempt: attempt,
      timer_ref: timer_ref
    })
  end

  defp cancel_reconnect(name, state) do
    case Map.pop(state.reconnecting, name) do
      {%{timer_ref: timer_ref}, reconnecting} ->
        Process.cancel_timer(timer_ref)
        %{state | reconnecting: reconnecting}

      {nil, _reconnecting} ->
        state
    end
  end

  defp reconnect_delay(attempt, initial_backoff_ms) do
    trunc(initial_backoff_ms * :math.pow(2, attempt - 1))
  end

  defp restore_executor_capacity(state) do
    if server_alive?(state.lease_manager_server) do
      state.lease_manager_module.restore_capacity(state.lease_manager_server)
    end
  end

  defp release_executor_capacity(node, state) do
    if server_alive?(state.lease_manager_server) do
      state.lease_manager_module.release_node_capacity(state.lease_manager_server, node)
    end
  end

  defp reconcile_node(node, reason, state) do
    case state.reconciler.reconcile_node(node,
           reason: reason,
           redis_store: state.redis_store,
           event_bus: state.event_bus
         ) do
      {:ok, result} ->
        Logger.info("reconciled jobs for unavailable node #{node}: #{inspect(result)}")

      {:error, reconcile_reason} ->
        Logger.warning(
          "failed to reconcile jobs for unavailable node #{node}: #{inspect(reconcile_reason)}"
        )
    end
  end

  defp config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> normalize_positive_integer(value, default)
    end
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp server_alive?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp server_alive?(server) when is_pid(server), do: Process.alive?(server)
  defp server_alive?(_server), do: false

  defp node_state(opts), do: Keyword.get(opts, :node_state, MirrorNeuron.Cluster.NodeState)
  defp node_name(node) when is_atom(node), do: Atom.to_string(node)
  defp node_name(node) when is_binary(node), do: node
  defp node_name(node), do: to_string(node)
end
