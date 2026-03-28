defmodule MirrorNeuron.Runtime.JobCoordinator do
  use GenServer

  alias MirrorNeuron.Message
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{AgentWorker, EventBus, Naming}

  def start_link({job_id, manifest, opts}) do
    GenServer.start_link(__MODULE__, {job_id, manifest, opts}, name: Naming.via_job(job_id))
  end

  @impl true
  def init({job_id, manifest, opts}) do
    bundle = Keyword.get(opts, :job_bundle)

    state = %{
      job_id: job_id,
      manifest: manifest,
      bundle: bundle,
      opts: opts,
      status: "pending",
      result: nil,
      submitted_at: Runtime.timestamp(),
      agent_ids: Enum.map(manifest.nodes, & &1.node_id)
    }

    persist_job(state)
    EventBus.publish(job_id, %{type: :job_pending, timestamp: Runtime.timestamp()})

    {:ok, state, {:continue, :bootstrap}}
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
      {:noreply, next_state}
    else
      {:error, reason} ->
        failed_state = %{state | status: "failed", result: %{error: reason}}
        persist_job(failed_state)

        EventBus.publish(state.job_id, %{
          type: :job_failed,
          reason: reason,
          timestamp: Runtime.timestamp()
        })

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
    next_state = %{state | status: "cancelled", result: %{reason: "cancelled by operator"}}
    persist_job(next_state)
    EventBus.publish(state.job_id, %{type: :job_cancelled, timestamp: Runtime.timestamp()})
    {:stop, :normal, {:ok, "cancelled"}, next_state}
  end

  @impl true
  def handle_call({:send_message, agent_id, message}, _from, state) do
    envelope = build_external_message(state.job_id, agent_id, message)

    case Runtime.deliver(state.job_id, agent_id, envelope) do
      :ok -> {:reply, {:ok, "delivered"}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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
    RedisStore.persist_agent(state.job_id, agent_id, snapshot)
    {:noreply, state}
  end

  def handle_info({:agent_completed_job, agent_id, result}, state) do
    next_state = %{state | status: "completed", result: %{agent_id: agent_id, output: result}}
    persist_job(next_state)

    EventBus.publish(state.job_id, %{
      type: :job_completed,
      agent_id: agent_id,
      result: result,
      timestamp: Runtime.timestamp()
    })

    {:stop, :normal, next_state}
  end

  def handle_info({:agent_failed, agent_id, reason}, state) do
    next_state = %{
      state
      | status: "failed",
        result: %{agent_id: agent_id, error: inspect(reason)}
    }

    persist_job(next_state)

    EventBus.publish(state.job_id, %{
      type: :job_failed,
      agent_id: agent_id,
      reason: inspect(reason),
      timestamp: Runtime.timestamp()
    })

    {:stop, {:shutdown, reason}, next_state}
  end

  defp start_agents(state) do
    Enum.reduce_while(state.manifest.nodes, :ok, fn node, :ok ->
      spec =
        {AgentWorker,
         {state.job_id, node, state.manifest.edges, self(), agent_runtime_context(state)}}

      case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.AgentSupervisor, spec) do
        {:ok, _pid} ->
          {:cont, :ok}

        {:error, {:already_started, _pid}} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, "failed to start agent #{node.node_id}: #{inspect(reason)}"}}
      end
    end)
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

  defp wait_for_agents_ready(state, timeout_ms \\ 5_000) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_agents_ready(state, started_at, timeout_ms)
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
    job_map = %{
      job_id: state.job_id,
      graph_id: state.manifest.graph_id,
      job_name: state.manifest.job_name,
      status: state.status,
      submitted_at: Map.get(state, :submitted_at, Runtime.timestamp()),
      updated_at: Runtime.timestamp(),
      root_agent_ids: state.manifest.entrypoints,
      placement_policy: Map.get(state.manifest.policies, "placement_policy", "local"),
      recovery_policy: Map.get(state.manifest.policies, "recovery_mode", "local_restart"),
      result: state.result,
      manifest_ref: %{
        graph_id: state.manifest.graph_id,
        manifest_version: state.manifest.manifest_version,
        manifest_path: state.bundle && state.bundle.manifest_path,
        job_path: state.bundle && state.bundle.root_path
      }
    }

    RedisStore.persist_job(state.job_id, job_map)
  end

  defp agent_runtime_context(state) do
    %{
      bundle_root: state.bundle && state.bundle.root_path,
      manifest_path: state.bundle && state.bundle.manifest_path,
      payloads_path: state.bundle && state.bundle.payloads_path
    }
  end

  defp unique_id do
    6
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
