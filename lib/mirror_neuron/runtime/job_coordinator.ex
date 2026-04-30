defmodule MirrorNeuron.Runtime.JobCoordinator do
  use GenServer
  require Logger

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{AgentWorker, Backpressure, EventBus, Naming}
  alias MirrorNeuron.Sandbox.JobSandbox

  @default_health_check_interval_ms 2_000
  @default_max_agent_restart_attempts 3

  def start_link({job_id, manifest, opts}) do
    GenServer.start_link(__MODULE__, {job_id, manifest, opts}, name: Naming.via_job(job_id))
  end

  @impl true
  def init({job_id, manifest, opts}) do
    bundle = Keyword.get(opts, :job_bundle)

    existing_job =
      case RedisStore.fetch_job(job_id) do
        {:ok, job_map} when is_map(job_map) -> job_map
        _ -> nil
      end

    status = if existing_job, do: existing_job["status"], else: "pending"
    submitted_at = if existing_job, do: existing_job["submitted_at"], else: Runtime.timestamp()
    result = if existing_job, do: existing_job["result"], else: nil

    state = %{
      job_id: job_id,
      manifest: manifest,
      bundle: bundle,
      opts: opts,
      status: status,
      result: result,
      submitted_at: submitted_at,
      agent_ids: Enum.map(manifest.nodes, & &1.node_id),
      nodes_by_id: Map.new(manifest.nodes, &{&1.node_id, &1}),
      outbound_edges_by_node: Enum.group_by(manifest.edges, & &1.from_node),
      inbound_edges_by_node: Enum.group_by(manifest.edges, & &1.to_node),
      downstream_by_node: build_downstream_index(manifest.edges),
      pressure: %{},
      agent_restart_attempts: %{},
      max_agent_restart_attempts:
        Map.get(
          manifest.policies,
          "max_agent_restart_attempts",
          @default_max_agent_restart_attempts
        ),
      health_check_interval_ms:
        Application.get_env(
          :mirror_neuron,
          :job_health_check_interval_ms,
          @default_health_check_interval_ms
        )
    }

    if status == "pending" do
      persist_job(state)
      EventBus.publish(job_id, %{type: :job_pending, timestamp: Runtime.timestamp()})
      {:ok, state, {:continue, :bootstrap}}
    else
      EventBus.publish(job_id, %{type: :job_recovery_started, timestamp: Runtime.timestamp()})
      {:ok, state, {:continue, :recover}}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    schedule_health_check(100)
    {:noreply, state}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    EventBus.publish(state.job_id, %{type: :job_validated, timestamp: Runtime.timestamp()})

    EventBus.publish(state.job_id, %{
      type: :job_scheduled,
      node: to_string(Node.self()),
      timestamp: Runtime.timestamp()
    })

    with :ok <- start_agents(state),
         :ok <- wait_for_agents_ready(state),
         :ok <- seed_entrypoints(state) do
      next_state = %{state | status: "running"}
      persist_job(next_state)
      EventBus.publish(state.job_id, %{type: :job_running, timestamp: Runtime.timestamp()})
      schedule_health_check(next_state.health_check_interval_ms)
      {:noreply, next_state}
    else
      {:error, reason} ->
        failed_state =
          finalize_job(state, "failed", %{error: reason}, :job_failed, %{reason: reason})

        {:stop, {:shutdown, reason}, failed_state}
    end
  end

  @impl true
  def handle_call(:pause, _from, %{status: "running"} = state) do
    broadcast_agent_control(state, :pause)
    next_state = %{state | status: "paused"}
    persist_job(next_state)
    EventBus.publish(state.job_id, %{type: :job_paused, timestamp: Runtime.timestamp()})
    {:reply, {:ok, "paused"}, next_state}
  end

  def handle_call(:pause, _from, state), do: {:reply, {:error, "job is not running"}, state}

  @impl true
  def handle_call(:resume, _from, %{status: "paused"} = state) do
    broadcast_agent_control(state, :resume)
    next_state = %{state | status: "running"}
    persist_job(next_state)
    EventBus.publish(state.job_id, %{type: :job_resumed, timestamp: Runtime.timestamp()})
    {:reply, {:ok, "resumed"}, next_state}
  end

  def handle_call(:resume, _from, state), do: {:reply, {:error, "job is not paused"}, state}

  @impl true
  def handle_call(:cancel, _from, state) do
    broadcast_agent_control(state, :cancel)

    next_state =
      finalize_job(
        state,
        "cancelled",
        %{reason: "cancelled by operator"},
        :job_cancelled,
        %{}
      )

    {:stop, :normal, {:ok, "cancelled"}, next_state}
  end

  @impl true
  def handle_call({:send_message, agent_id, message}, _from, state) do
    envelope = build_external_message(state.job_id, agent_id, message)
    state = refresh_pressure(state)

    case external_input_pressure(state, agent_id) do
      {:retry_later, details} ->
        EventBus.publish(state.job_id, %{
          type: :external_input_rejected,
          agent_id: agent_id,
          payload: details,
          timestamp: Runtime.timestamp()
        })

        {:reply, {:error, {:retry_later, details}}, state}

      :ok ->
        case Runtime.deliver(
               state.job_id,
               agent_id,
               envelope,
               node_backpressure_opts(state, agent_id)
             ) do
          :ok -> {:reply, {:ok, "delivered"}, state}
          {:error, {:backpressure, details}} -> {:reply, {:error, {:retry_later, details}}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:pressure, _from, state) do
    next_state = refresh_pressure(state)
    {:reply, {:ok, pressure_summary(next_state)}, next_state}
  end

  @impl true
  def handle_info({:agent_event, agent_id, event_type, payload}, state) do
    EventBus.publish(state.job_id, %{
      type: event_type,
      agent_id: agent_id,
      payload: payload,
      timestamp: Runtime.timestamp()
    })

    {:noreply, state}
  end

  def handle_info({:agent_checkpoint, agent_id, snapshot}, state) do
    case RedisStore.persist_agent(state.job_id, agent_id, snapshot) do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to persist agent checkpoint for #{state.job_id}/#{agent_id}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_info({:agent_pressure, agent_id, pressure}, state) do
    previous = Map.get(state.pressure, agent_id)
    next_state = put_in(state.pressure[agent_id], pressure)

    if pressure_event_changed?(previous, pressure) do
      EventBus.publish(state.job_id, %{
        type: :backpressure_state,
        agent_id: agent_id,
        payload: pressure,
        timestamp: Runtime.timestamp()
      })
    end

    {:noreply, next_state}
  end

  def handle_info({:agent_completed_job, agent_id, result}, state) do
    next_state =
      finalize_job(
        state,
        "completed",
        %{agent_id: agent_id, output: result},
        :job_completed,
        %{agent_id: agent_id, result: result}
      )

    {:stop, :normal, next_state}
  end

  def handle_info({:agent_failed, agent_id, reason}, state) do
    next_state =
      finalize_job(
        state,
        "failed",
        %{agent_id: agent_id, error: inspect(reason)},
        :job_failed,
        %{agent_id: agent_id, reason: inspect(reason)}
      )

    {:stop, {:shutdown, reason}, next_state}
  end

  def handle_info(:health_check, %{status: status} = state)
      when status in ["running", "paused"] do
    state = refresh_pressure(state)

    case recover_missing_agents(state) do
      {:ok, next_state} ->
        schedule_health_check(next_state.health_check_interval_ms)
        {:noreply, next_state}

      {:error, reason, next_state} ->
        failed_state =
          finalize_job(
            next_state,
            "failed",
            %{agent_id: "job_coordinator", error: reason},
            :job_failed,
            %{agent_id: "job_coordinator", reason: reason}
          )

        {:stop, {:shutdown, reason}, failed_state}
    end
  end

  def handle_info(:health_check, state), do: {:noreply, state}

  defp start_agents(state) do
    Enum.reduce_while(state.manifest.nodes, :ok, fn node, :ok ->
      case start_agent(state, node.node_id) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, {:already_started, _pid}} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "failed to start agent #{node.node_id}: #{inspect(reason)}"}}
      end
    end)
  end

  defp refresh_pressure(state) do
    pressure =
      Enum.reduce(state.agent_ids, state.pressure, fn agent_id, acc ->
        case agent_pressure_snapshot(state, agent_id) do
          nil -> acc
          snapshot -> Map.put(acc, agent_id, snapshot)
        end
      end)

    pressure
    |> Enum.filter(fn {agent_id, snapshot} ->
      pressure_event_changed?(Map.get(state.pressure, agent_id), snapshot)
    end)
    |> Enum.each(fn {agent_id, snapshot} ->
      EventBus.publish(state.job_id, %{
        type: :backpressure_state,
        agent_id: agent_id,
        payload: snapshot,
        timestamp: Runtime.timestamp()
      })
    end)

    %{state | pressure: pressure}
  end

  defp pressure_event_changed?(previous, pressure) when is_map(previous) and is_map(pressure) do
    Backpressure.pressured?(pressure) and
      (Map.get(previous, "status") != Map.get(pressure, "status") or
         Map.get(previous, "queue_depth") != Map.get(pressure, "queue_depth"))
  end

  defp pressure_event_changed?(_previous, pressure) do
    Backpressure.pressured?(pressure)
  end

  defp agent_pressure_snapshot(state, agent_id) do
    with [{pid, _meta}] <-
           Horde.Registry.lookup(
             MirrorNeuron.DistributedRegistry,
             {:agent, state.job_id, agent_id}
           ) do
      node = Map.fetch!(state.nodes_by_id, agent_id)
      queue_depth = Backpressure.process_queue_depth(pid)
      Backpressure.snapshot(agent_id, node, queue_depth, [], Map.get(state.pressure, agent_id))
    else
      _ -> nil
    end
  end

  defp external_input_pressure(state, agent_id) do
    impacted_agents = [agent_id | Map.get(state.downstream_by_node, agent_id, [])]

    state.pressure
    |> Map.take(impacted_agents)
    |> Enum.find(fn {_id, snapshot} -> Backpressure.pressured?(snapshot) end)
    |> case do
      nil ->
        :ok

      {pressured_agent_id, snapshot} ->
        {:retry_later,
         Backpressure.retry_later_reason(snapshot, %{
           "target_agent_id" => agent_id,
           "pressured_agent_id" => pressured_agent_id,
           "affected_agents" => impacted_agents,
           "accepted" => false
         })}
    end
  end

  defp pressure_summary(state) do
    %{
      "job_id" => state.job_id,
      "pressured" =>
        state.pressure
        |> Enum.filter(fn {_id, snapshot} -> Backpressure.pressured?(snapshot) end)
        |> Enum.map(fn {id, snapshot} -> Map.put(snapshot, "agent_id", id) end),
      "agents" => state.pressure
    }
  end

  defp seed_entrypoints(state) do
    inputs = state.manifest.initial_inputs

    Enum.reduce_while(state.manifest.entrypoints, :ok, fn agent_id, :ok ->
      payloads =
        Map.get(inputs, agent_id) ||
          Map.get(inputs, "__entrypoints__") ||
          [%{}]

      result =
        Enum.reduce_while(payloads, :ok, fn payload, :ok ->
          message =
            Message.normalize!(
              payload,
              job_id: state.job_id,
              from: "runtime",
              to: agent_id,
              type: "init",
              class: "command",
              correlation_id: unique_id()
            )

          case Runtime.deliver(state.job_id, agent_id, message) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp wait_for_agents_ready(state, timeout_ms \\ 20_000) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agents_ready(state, started_at, timeout_ms)
  end

  defp recover_missing_agents(state) do
    Enum.reduce_while(state.agent_ids, {:ok, state}, fn agent_id, {:ok, acc_state} ->
      if agent_ready?(acc_state, agent_id) do
        {:cont, {:ok, acc_state}}
      else
        case recover_agent(acc_state, agent_id) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
        end
      end
    end)
  end

  defp recover_agent(state, agent_id) do
    attempts = Map.get(state.agent_restart_attempts, agent_id, 0)

    if restart_attempts_exhausted?(state, attempts) do
      {:error,
       "agent #{agent_id} exceeded restart attempts (#{state.max_agent_restart_attempts})", state}
    else
      recovery_snapshot =
        case RedisStore.fetch_agent(state.job_id, agent_id) do
          {:ok, snapshot} -> snapshot
          _ -> nil
        end

      EventBus.publish(state.job_id, %{
        type: :agent_recovery_started,
        agent_id: agent_id,
        attempt: attempts + 1,
        timestamp: Runtime.timestamp()
      })

      case start_agent(state, agent_id, recovery_snapshot) do
        {:ok, _pid} ->
          wait_result = wait_for_agent_ready(state, agent_id, 30_000)

          case wait_result do
            :ok ->
              EventBus.publish(state.job_id, %{
                type: :agent_recovered,
                agent_id: agent_id,
                attempt: attempts + 1,
                timestamp: Runtime.timestamp()
              })

              {:ok, put_in(state.agent_restart_attempts[agent_id], attempts + 1)}

            {:error, reason} ->
              {:error, reason, state}
          end

        {:error, {:already_started, _pid}} ->
          {:ok, state}

        {:error, reason} ->
          {:error, "failed to recover agent #{agent_id}: #{inspect(reason)}", state}
      end
    end
  end

  defp restart_attempts_exhausted?(%{manifest: %{daemon: true}}, _attempts), do: false

  defp restart_attempts_exhausted?(state, attempts) do
    attempts >= state.max_agent_restart_attempts
  end

  defp start_agent(state, agent_id, recovery_snapshot \\ nil, retry_count \\ 0) do
    node = Map.fetch!(state.nodes_by_id, agent_id)

    spec =
      {AgentWorker,
       {state.job_id, node, Map.get(state.outbound_edges_by_node, agent_id, []),
        Map.get(state.inbound_edges_by_node, agent_id, []), self(), agent_runtime_context(state),
        recovery_snapshot}}

    case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.AgentSupervisor, spec) do
      {:error, {:already_started, _pid}} when retry_count < 10 ->
        Process.sleep(100)
        start_agent(state, agent_id, recovery_snapshot, retry_count + 1)

      other ->
        other
    end
  end

  defp wait_for_agent_ready(state, agent_id, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms)
  end

  defp do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms) do
    if agent_ready?(state, agent_id) do
      :ok
    else
      if System.monotonic_time(:millisecond) - started_at > timeout_ms do
        {:error, "timed out waiting for recovered agent #{agent_id} to register"}
      else
        Process.sleep(25)
        do_wait_for_agent_ready(state, agent_id, started_at, timeout_ms)
      end
    end
  end

  defp agent_ready?(state, agent_id) do
    match?(
      [{_pid, _meta}],
      Horde.Registry.lookup(
        MirrorNeuron.DistributedRegistry,
        {:agent, state.job_id, agent_id}
      )
    )
  end

  defp schedule_health_check(interval_ms) do
    Process.send_after(self(), :health_check, interval_ms)
  end

  defp build_downstream_index(edges) do
    direct = Enum.group_by(edges, & &1.from_node, & &1.to_node)

    direct
    |> Map.keys()
    |> Enum.into(%{}, fn node_id ->
      {node_id, downstream_closure(node_id, direct, MapSet.new())}
    end)
  end

  defp downstream_closure(node_id, direct, visited) do
    direct
    |> Map.get(node_id, [])
    |> Enum.reject(&MapSet.member?(visited, &1))
    |> Enum.flat_map(fn child ->
      [child | downstream_closure(child, direct, MapSet.put(visited, child))]
    end)
    |> Enum.uniq()
  end

  defp do_wait_for_agents_ready(state, started_at, timeout_ms) do
    missing_agents =
      Enum.reject(state.agent_ids, fn agent_id ->
        match?(
          [{_pid, _meta}],
          Horde.Registry.lookup(
            MirrorNeuron.DistributedRegistry,
            {:agent, state.job_id, agent_id}
          )
        )
      end)

    case missing_agents do
      [] ->
        :ok

      missing ->
        if System.monotonic_time(:millisecond) - started_at > timeout_ms do
          {:error, "timed out waiting for agents to register: #{Enum.join(missing, ", ")}"}
        else
          Process.sleep(25)
          do_wait_for_agents_ready(state, started_at, timeout_ms)
        end
    end
  end

  defp broadcast_agent_control(state, command) do
    Enum.each(state.agent_ids, fn agent_id ->
      case Horde.Registry.lookup(
             MirrorNeuron.DistributedRegistry,
             {:agent, state.job_id, agent_id}
           ) do
        [{pid, _}] -> GenServer.cast(pid, command)
        [] -> :ok
      end
    end)
  end

  defp terminate_agent_workers(state) do
    Enum.each(state.agent_ids, fn agent_id ->
      case Horde.Registry.lookup(
             MirrorNeuron.DistributedRegistry,
             {:agent, state.job_id, agent_id}
           ) do
        [{pid, _}] ->
          case Horde.DynamicSupervisor.terminate_child(MirrorNeuron.Runtime.AgentSupervisor, pid) do
            :ok ->
              :ok

            {:error, :not_found} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "failed to terminate agent #{state.job_id}/#{agent_id}: #{inspect(reason)}"
              )

              if Process.alive?(pid), do: Process.exit(pid, :kill)
          end

        [] ->
          :ok
      end
    end)
  end

  defp finalize_job(state, status, result, event_type, event_fields) do
    terminate_agent_workers(state)

    next_state = %{state | status: status, result: result}
    persist_job(next_state)
    cleanup_sandboxes(next_state)

    event =
      event_fields
      |> Map.put(:type, event_type)
      |> Map.put(:timestamp, Runtime.timestamp())

    EventBus.publish(state.job_id, event)
    next_state
  end

  defp build_external_message(job_id, agent_id, message) do
    Message.normalize!(
      message,
      job_id: job_id,
      from: "external",
      to: agent_id,
      type: "command",
      class: "command",
      correlation_id: unique_id()
    )
  end

  defp persist_job(state) do
    lease = Keyword.get(state.opts, :job_lease)

    job_map = %{
      job_id: state.job_id,
      graph_id: state.manifest.graph_id,
      job_name: state.manifest.job_name,
      required_context_engine: Map.get(state.manifest, :required_context_engine, false),
      status: state.status,
      submitted_at: Map.get(state, :submitted_at, Runtime.timestamp()),
      updated_at: Runtime.timestamp(),
      root_agent_ids: state.manifest.entrypoints,
      placement_policy: Map.get(state.manifest.policies, "placement_policy", "local"),
      recovery_policy: Map.get(state.manifest.policies, "recovery_mode", "local_restart"),
      result: state.result,
      topology: MirrorNeuron.Manifest.topology(state.manifest),
      manifest_ref: manifest_ref(state)
    }
    |> maybe_put_lease(lease)

    case RedisStore.persist_job(state.job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to persist job #{state.job_id}: #{inspect(reason)}")
    end
  end

  defp cleanup_sandboxes(state) do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.each(fn node ->
      case :rpc.call(node, JobSandbox, :cleanup_job_local, [state.job_id], 15_000) do
        :ok ->
          :ok

        {:badrpc, reason} ->
          Logger.warning(
            "failed to clean up shared sandbox for #{state.job_id} on #{node}: #{inspect(reason)}"
          )

        _other ->
          :ok
      end
    end)
  end

  defp agent_runtime_context(state) do
    lease = Keyword.get(state.opts, :job_lease)

    %{
      bundle_root: state.bundle && state.bundle.root_path,
      manifest_path: state.bundle && state.bundle.manifest_path,
      payloads_path: state.bundle && state.bundle.payloads_path,
      manifest_ref: manifest_ref(state),
      graph_id: state.manifest.graph_id,
      job_name: state.manifest.job_name,
      required_context_engine: Map.get(state.manifest, :required_context_engine, false),
      entrypoints: state.manifest.entrypoints,
      placement_policy: Map.get(state.manifest.policies, "placement_policy", "local"),
      recovery_policy: Map.get(state.manifest.policies, "recovery_mode", "local_restart"),
      submitted_at: state.submitted_at,
      manifest_version: state.manifest.manifest_version,
      lease_epoch: lease && lease["epoch"],
      lease_owner: lease && lease["owner_id"],
      backpressure_by_agent:
        Map.new(state.manifest.nodes, fn node ->
          {node.node_id, Backpressure.config(node) |> Map.to_list()}
        end)
    }
  end

  defp manifest_ref(state) do
    Keyword.get(state.opts, :bundle_ref) ||
      %{
        graph_id: state.manifest.graph_id,
        manifest_version: state.manifest.manifest_version,
        manifest_path: state.bundle && state.bundle.manifest_path,
        job_path: state.bundle && state.bundle.root_path
      }
  end

  defp maybe_put_lease(map, nil), do: map

  defp maybe_put_lease(map, lease) do
    map
    |> Map.put(:lease, lease)
    |> Map.put(:lease_epoch, lease["epoch"])
    |> Map.put(:lease_owner, lease["owner_id"])
  end

  defp node_backpressure_opts(state, agent_id) do
    state.nodes_by_id
    |> Map.get(agent_id, %{})
    |> Backpressure.config()
    |> Map.to_list()
  end

  defp unique_id do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
