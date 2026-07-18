defmodule MirrorNeuron.Cluster.NodeMonitor do
  use GenServer
  require Logger

  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.ServiceRegistry

  @default_reconnect_attempts 3
  @default_reconnect_backoff_ms 1_000
  @default_disconnect_grace_ms 30_000
  @default_health_probe_interval_ms 10_000
  @default_health_misses 3
  @default_health_probe_timeout_ms 2_000
  @default_self_advertise_retry_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    monitor_nodes = Keyword.get(opts, :monitor_nodes, true)

    if monitor_nodes do
      :net_kernel.monitor_nodes(true)
    end

    state = %{
      reconnecting: %{},
      disconnecting: %{},
      health_probe_timer_ref: nil,
      health_probe_token: nil,
      health_misses: %{},
      connect: Keyword.get(opts, :connect, &Node.connect/1),
      list_nodes: Keyword.get(opts, :list_nodes, &Node.list/0),
      health_probe: Keyword.get(opts, :health_probe, &default_health_probe/2),
      lease_manager_module:
        Keyword.get(opts, :lease_manager_module, MirrorNeuron.Execution.LeaseManager),
      lease_manager_server:
        Keyword.get(opts, :lease_manager_server, MirrorNeuron.Execution.LeaseManager),
      leader: Keyword.get(opts, :leader, MirrorNeuron.Cluster.Leader),
      node_state: node_state(opts),
      reconciler: Keyword.get(opts, :reconciler, Reconciler),
      redis_store: Keyword.get(opts, :redis_store, RedisStore),
      event_bus: Keyword.get(opts, :event_bus, EventBus),
      service_registry: Keyword.get(opts, :service_registry, ServiceRegistry),
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
          ),
      disconnect_grace_ms:
        Keyword.get(opts, :disconnect_grace_ms) ||
          config_non_negative_integer(
            "MN_NODE_DISCONNECT_GRACE_MS",
            :node_disconnect_grace_ms,
            @default_disconnect_grace_ms
          ),
      health_probe_interval_ms:
        Keyword.get(opts, :health_probe_interval_ms) ||
          config_non_negative_integer(
            "MN_NODE_HEALTH_PROBE_INTERVAL_MS",
            :node_health_probe_interval_ms,
            @default_health_probe_interval_ms
          ),
      health_misses_allowed:
        Keyword.get(opts, :health_misses) ||
          config_positive_integer(
            "MN_NODE_HEALTH_MISSES",
            :node_health_misses,
            @default_health_misses
          ),
      health_probe_timeout_ms:
        Keyword.get(opts, :health_probe_timeout_ms) ||
          config_positive_integer(
            "MN_NODE_HEALTH_PROBE_TIMEOUT_MS",
            :node_health_probe_timeout_ms,
            @default_health_probe_timeout_ms
          ),
      self_advertise_retry_ms:
        Keyword.get(opts, :self_advertise_retry_ms, @default_self_advertise_retry_ms)
    }

    state = if monitor_nodes, do: advertise_self(state), else: state

    {:ok, schedule_health_probe(state)}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.notice("Node joined cluster: #{node}")

    state =
      node
      |> node_name()
      |> cancel_reconnect(state)
      |> cancel_disconnect(node_name(node))
      |> clear_health_misses(node_name(node))

    restore_executor_capacity(state)
    mark_node_connected(state.node_state, node)
    wake_blocked_evals(node, state)
    Logger.notice("Node reconnected: #{node}")
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    {:noreply, begin_reconnect(node, "Node left cluster: #{node}", state)}
  end

  def handle_info({:reconnect_node, node, attempt, token}, state) do
    name = node_name(node)

    case Map.get(state.reconnecting, name) do
      %{attempt: ^attempt, token: ^token} ->
        reconnect_node(node, attempt, state)

      _stale_or_cancelled ->
        {:noreply, state}
    end
  end

  def handle_info({:disconnect_grace_expired, node, wait_until, token}, state) do
    name = node_name(node)

    case Map.get(state.disconnecting, name) do
      %{wait_until: ^wait_until, token: ^token} ->
        {:noreply, complete_disconnect(node, state)}

      _stale_or_cancelled ->
        {:noreply, state}
    end
  end

  def handle_info({:health_probe, token}, %{health_probe_token: token} = state) do
    state = clear_health_probe_timer(state)

    state =
      state
      |> run_health_probes()
      |> schedule_health_probe()

    {:noreply, state}
  end

  def handle_info({:health_probe, _stale_token}, state), do: {:noreply, state}

  def handle_info(:health_probe, state), do: {:noreply, run_health_probes(state)}

  def handle_info(:advertise_self, state), do: {:noreply, advertise_self(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = cancel_health_probe(state)
    Enum.each(state.reconnecting, fn {_name, entry} -> Process.cancel_timer(entry.timer_ref) end)
    Enum.each(state.disconnecting, fn {_name, entry} -> Process.cancel_timer(entry.timer_ref) end)
    :ok
  end

  defp begin_reconnect(node, log_message, state) do
    Logger.notice(log_message)
    state.node_state.mark(node, "reconnecting")

    state
    |> clear_health_misses(node_name(node))
    |> then(&schedule_reconnect(node, 1, &1))
  end

  defp run_health_probes(state) do
    state.list_nodes.()
    |> Enum.reject(&(&1 == Node.self()))
    |> Enum.reduce(state, fn node, acc -> probe_node(node, acc) end)
  end

  defp probe_node(node, state) do
    name = node_name(node)

    cond do
      Map.has_key?(state.reconnecting, name) ->
        state

      Map.has_key?(state.disconnecting, name) ->
        state

      state.health_probe.(node, state.health_probe_timeout_ms) ->
        clear_health_misses(state, name)

      true ->
        misses = Map.get(state.health_misses, name, 0) + 1
        state = put_in(state.health_misses[name], misses)

        if misses >= state.health_misses_allowed do
          begin_reconnect(
            node,
            "Node health probe failed #{misses} time(s): #{node}",
            state
          )
        else
          state
        end
    end
  end

  defp reconnect_node(node, attempt, state) do
    if state.connect.(node) do
      Logger.notice("Node reconnected after #{attempt} attempt(s): #{node}")
      restore_executor_capacity(state)
      mark_node_connected(state.node_state, node)
      wake_blocked_evals(node, state)

      state =
        node
        |> node_name()
        |> cancel_reconnect(state)
        |> clear_health_misses(node_name(node))

      {:noreply, state}
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

    state =
      node
      |> node_name()
      |> cancel_reconnect(state)
      |> clear_health_misses(node_name(node))

    if state.disconnect_grace_ms > 0 do
      wait_until = iso_after(state.disconnect_grace_ms)

      state.node_state.mark(node, "disconnected", %{
        "reason" => reason,
        "disconnect_expires_at" => wait_until,
        "lost_after_ms" => state.disconnect_grace_ms
      })

      reconcile_node(node, reason, state, node_status: "disconnected", wait_until: wait_until)
      schedule_disconnect_grace(node, wait_until, state)
    else
      state.node_state.mark(node, "offline")
      reconcile_node(node, reason, state, node_status: "offline")
      deregister_node_services(node, state)
      state.leader.node_down(node)
      state
    end
  end

  defp complete_disconnect(node, state) do
    reason = "node disconnect grace expired"

    Logger.warning("#{reason}: #{node}")
    state.node_state.mark(node, "offline", %{"reason" => reason})
    reconcile_node(node, reason, state, node_status: "offline", force: true)
    deregister_node_services(node, state)
    state.leader.node_down(node)

    cancel_disconnect(state, node_name(node))
  end

  defp schedule_reconnect(node, attempt, state) do
    name = node_name(node)
    state = cancel_reconnect(name, state)
    delay = reconnect_delay(attempt, state.reconnect_backoff_ms)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:reconnect_node, node, attempt, token}, delay)

    put_in(state.reconnecting[name], %{
      node: node,
      attempt: attempt,
      token: token,
      timer_ref: timer_ref
    })
  end

  defp schedule_disconnect_grace(node, wait_until, state) do
    name = node_name(node)
    state = cancel_disconnect(state, name)
    token = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:disconnect_grace_expired, node, wait_until, token},
        state.disconnect_grace_ms
      )

    put_in(state.disconnecting[name], %{
      node: node,
      wait_until: wait_until,
      token: token,
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

  defp cancel_disconnect(state, name) do
    case Map.pop(state.disconnecting, name) do
      {%{timer_ref: timer_ref}, disconnecting} ->
        Process.cancel_timer(timer_ref)
        %{state | disconnecting: disconnecting}

      {nil, _disconnecting} ->
        state
    end
  end

  defp clear_health_misses(state, name) do
    %{state | health_misses: Map.delete(state.health_misses, name)}
  end

  defp schedule_health_probe(%{health_probe_interval_ms: interval_ms} = state)
       when interval_ms > 0 do
    state = cancel_health_probe(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:health_probe, token}, interval_ms)
    %{state | health_probe_timer_ref: timer_ref, health_probe_token: token}
  end

  defp schedule_health_probe(state), do: state

  defp cancel_health_probe(
         %{health_probe_timer_ref: timer_ref, health_probe_token: token} = state
       )
       when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)

    receive do
      {:health_probe, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_health_probe_timer(state)
  end

  defp cancel_health_probe(state), do: state

  defp clear_health_probe_timer(state),
    do: %{state | health_probe_timer_ref: nil, health_probe_token: nil}

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

  defp reconcile_node(node, reason, state, extra_opts) do
    opts =
      [
        reason: reason,
        redis_store: state.redis_store,
        event_bus: state.event_bus
      ]
      |> Keyword.merge(extra_opts)

    case state.reconciler.reconcile_node(node, opts) do
      {:ok, result} ->
        Logger.info("reconciled jobs for unavailable node #{node}: #{inspect(result)}")

      {:error, reconcile_reason} ->
        Logger.warning(
          "failed to reconcile jobs for unavailable node #{node}: #{inspect(reconcile_reason)}"
        )
    end
  end

  defp deregister_node_services(node, state) do
    if function_exported?(state.service_registry, :deregister_node, 1) do
      _ = state.service_registry.deregister_node(to_string(node))
    end
  rescue
    _ -> :ok
  end

  defp wake_blocked_evals(node, state) do
    if function_exported?(state.reconciler, :wake_blocked_evals, 1) do
      _ =
        state.reconciler.wake_blocked_evals(
          reason: "node #{node} is healthy",
          redis_store: state.redis_store,
          event_bus: state.event_bus
        )
    end

    :ok
  end

  defp config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> normalize_positive_integer(value, default)
    end
  end

  defp config_non_negative_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> normalize_non_negative_integer(value, default)
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

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_non_negative_integer(_value, default), do: default

  defp iso_after(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(delay_ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp server_alive?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp server_alive?(server) when is_pid(server), do: Process.alive?(server)
  defp server_alive?(_server), do: false

  defp node_state(opts), do: Keyword.get(opts, :node_state, MirrorNeuron.Cluster.NodeState)

  defp mark_node_connected(node_state, node) do
    if function_exported?(node_state, :mark_connected, 1) do
      node_state.mark_connected(node)
    else
      node_state.mark(node, "healthy")
    end
  end

  defp advertise_self(state) do
    case state.node_state.advertise_self("healthy", %{"self" => true}) do
      :ok ->
        state

      {:ok, _advertisement} ->
        state

      {:error, reason} ->
        retry_self_advertisement(state, reason)

      other ->
        retry_self_advertisement(state, other)
    end
  rescue
    exception -> retry_self_advertisement(state, Exception.message(exception))
  catch
    kind, reason -> retry_self_advertisement(state, {kind, reason})
  end

  defp retry_self_advertisement(state, reason) do
    Logger.warning(
      "could not advertise local cluster node; retrying in #{state.self_advertise_retry_ms}ms: #{inspect(reason)}"
    )

    Process.send_after(self(), :advertise_self, state.self_advertise_retry_ms)
    state
  end

  defp node_name(node) when is_atom(node), do: Atom.to_string(node)
  defp node_name(node) when is_binary(node), do: node
  defp node_name(node), do: to_string(node)

  defp default_health_probe(node, timeout_ms) do
    case :rpc.call(node, :erlang, :node, [], timeout_ms) do
      ^node -> true
      _other -> false
    end
  end
end
