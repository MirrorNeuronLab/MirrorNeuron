defmodule MirrorNeuron.Runtime.JobRunner do
  use GenServer
  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{ErrorEnvelope, EventBus, JobCoordinator, LifecyclePolicy}
  alias MirrorNeuron.Runtime.Naming

  @active_statuses ["pending", "running", "paused"]
  @terminal_statuses ["completed", "failed", "cancelled"]
  @default_lease_duration_ms 60_000
  @default_lease_renew_interval_ms 10_000
  @max_lease_renew_failures 3

  def lease_duration_ms,
    do:
      config_positive_integer(
        "MN_JOB_LEASE_DURATION_MS",
        :job_lease_duration_ms,
        @default_lease_duration_ms
      )

  def lease_renew_interval_ms,
    do:
      config_positive_integer(
        "MN_JOB_LEASE_RENEW_INTERVAL_MS",
        :job_lease_renew_interval_ms,
        @default_lease_renew_interval_ms
      )

  def child_spec({job_id, manifest, opts}) do
    %{
      id: {:job_runner, job_id},
      start: {__MODULE__, :start_link, [{job_id, manifest, opts}]},
      restart: :transient,
      type: :worker
    }
    |> put_target_node(Keyword.get(opts, :preferred_start_node))
  end

  defp put_target_node(spec, nil), do: spec
  defp put_target_node(spec, ""), do: spec

  defp put_target_node(spec, node_name) do
    Map.put(spec, :mirror_neuron_target_node, to_string(node_name))
  end

  def start_link({job_id, manifest, opts}) do
    GenServer.start_link(__MODULE__, {job_id, manifest, opts},
      name: Naming.via_job_runner(job_id)
    )
  end

  @impl true
  def init({job_id, manifest, opts}) do
    Process.flag(:trap_exit, true)

    lease_name = "job:#{job_id}"
    node_name = to_string(Node.self())
    opts = put_bundle_ref(opts, manifest)

    case acquire_job_lease(lease_name, node_name) do
      {:ok, lease} ->
        start_coordinator_with_lease(job_id, manifest, opts, node_name, lease)

      {:error, {:locked, _owner}} ->
        {:stop, :normal}

      {:error, reason} ->
        fail_runner_start(job_id, manifest, opts, nil, reason)
    end
  end

  defp start_coordinator_with_lease(job_id, manifest, opts, node_name, lease) do
    opts = Keyword.put(opts, :job_lease, lease)

    with :ok <- persist_lease_owner(job_id, manifest, opts, lease),
         {:ok, pid} <- JobCoordinator.start_link({job_id, manifest, opts}) do
      state = %{
        job_id: job_id,
        manifest: manifest,
        bundle: Keyword.get(opts, :job_bundle),
        bundle_ref: Keyword.get(opts, :bundle_ref),
        opts: opts,
        coordinator: pid,
        node_name: node_name,
        lease: lease,
        lease_failures: 0,
        lease_timer_ref: nil,
        lease_timer_token: nil
      }

      {:ok, schedule_lease_renewal(state)}
    else
      {:error, reason} ->
        release_job_lease(job_id, node_name, lease)
        fail_runner_start(job_id, manifest, opts, lease, reason, clear_lease?: true)
    end
  end

  defp fail_runner_start(job_id, manifest, opts, lease, reason, failure_opts \\ []) do
    Logger.warning("failed to start job coordinator for #{job_id}: #{inspect(reason)}")

    persist_runner_failure(
      job_id,
      manifest,
      Keyword.get(opts, :job_bundle),
      Keyword.get(opts, :bundle_ref),
      lease,
      opts,
      reason,
      failure_opts
    )

    {:stop, reason}
  end

  @impl true
  def handle_info({:renew_lease, token}, %{lease_timer_token: token} = state) do
    state = clear_lease_timer(state)
    renew_lease(state, true)
  end

  def handle_info({:renew_lease, _stale_token}, state), do: {:noreply, state}

  def handle_info(:renew_lease, state), do: renew_lease(state, false)

  def handle_info({:EXIT, pid, reason}, %{coordinator: pid} = state) do
    exit_action = classify_coordinator_exit(state, reason)

    stop_reason = if exit_action == :restart, do: {:coordinator_exit, reason}, else: :normal

    {:stop, stop_reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp renew_lease(state, reschedule?) do
    lease_name = "job:#{state.job_id}"

    case RedisStore.renew_fenced_lease(
           lease_name,
           state.node_name,
           state.lease["epoch"],
           lease_duration_ms()
         ) do
      :ok ->
        state = %{state | lease_failures: 0}
        {:noreply, maybe_schedule_lease_renewal(state, reschedule?)}

      {:error, :not_owner} ->
        Logger.warning("Lost lease for job #{state.job_id}. Shutting down.")

        EventBus.publish(state.job_id, %{
          type: :job_lease_lost,
          lease_epoch: state.lease["epoch"],
          lease_owner: state.node_name,
          timestamp: Runtime.timestamp()
        })

        {:stop, :normal, state}

      {:error, reason} ->
        failures = state.lease_failures + 1

        if failures >= @max_lease_renew_failures do
          Logger.warning(
            "failed to renew lease for job #{state.job_id} #{failures} times; shutting down: #{inspect(reason)}"
          )

          {:stop, {:shutdown, {:lease_unavailable, reason}}, %{state | lease_failures: failures}}
        else
          Logger.warning(
            "failed to renew lease for job #{state.job_id}; retrying: #{inspect(reason)}"
          )

          state = %{state | lease_failures: failures}
          {:noreply, maybe_schedule_lease_renewal(state, reschedule?)}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    cancel_lease_timer(state)
    stop_coordinator(state.coordinator)
    release_job_lease(state.job_id, state.node_name, state.lease)
    :ok
  end

  defp stop_coordinator(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)

    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.demonitor(monitor, [:flush])
        end
    end

    :ok
  end

  defp stop_coordinator(_pid), do: :ok

  defp release_job_lease(job_id, node_name, lease) do
    case RedisStore.release_fenced_lease("job:#{job_id}", node_name, lease["epoch"]) do
      :ok ->
        :ok

      {:error, :not_owner} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to release lease for job #{job_id}: #{inspect(reason)}")
        :ok
    end
  end

  defp classify_coordinator_exit(state, reason) do
    case RedisStore.fetch_job(state.job_id) do
      {:ok, %{"status" => status}} when status in @terminal_statuses ->
        :terminal

      {:ok, %{"status" => "paused"}} when reason == :normal ->
        :paused

      {:ok, %{"status" => status}} when status in @active_statuses and reason == :normal ->
        Logger.info(
          "job coordinator for #{state.job_id} stopped normally while job was #{status}; leaving job active for local recovery"
        )

        EventBus.publish(state.job_id, %{
          type: :job_recovery_scheduled,
          reason: "runtime stopped before terminal state",
          exit_reason: inspect(reason),
          timestamp: Runtime.timestamp()
        })

        :recover_later

      {:ok, %{"status" => status}} when status in @active_statuses and reason != :normal ->
        Logger.warning(
          "job coordinator for #{state.job_id} exited unexpectedly; scheduling recovery: #{inspect(reason)}"
        )

        EventBus.publish(state.job_id, %{
          type: :job_recovery_scheduled,
          reason: inspect(reason),
          timestamp: Runtime.timestamp()
        })

        :restart

      _ when reason == :normal ->
        Logger.info(
          "job coordinator for #{state.job_id} stopped normally before terminal persistence; leaving existing job state for local recovery"
        )

        EventBus.publish(state.job_id, %{
          type: :job_recovery_scheduled,
          reason: "runtime stopped before terminal state",
          exit_reason: inspect(reason),
          timestamp: Runtime.timestamp()
        })

        :recover_later

      _ ->
        Logger.warning(
          "job coordinator for #{state.job_id} exited before terminal persistence: #{inspect(reason)}"
        )

        persist_runner_failure(
          state.job_id,
          state.manifest,
          state.bundle,
          state.bundle_ref,
          state.lease,
          state.opts,
          reason
        )

        :failed
    end
  end

  defp acquire_job_lease(lease_name, node_name) do
    case RedisStore.acquire_fenced_lease(lease_name, node_name, lease_duration_ms()) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, {:locked, owner}} ->
        Logger.info("job lease #{lease_name} is already held by #{inspect(owner)}")
        {:error, {:locked, owner}}

      {:error, reason} ->
        {:error, {:lease_unavailable, reason}}
    end
  end

  defp put_bundle_ref(opts, manifest) do
    Keyword.put_new_lazy(opts, :bundle_ref, fn ->
      Runtime.bundle_ref(manifest, Keyword.get(opts, :job_bundle))
    end)
  end

  defp persist_lease_owner(job_id, manifest, opts, lease) do
    defaults = job_defaults(manifest, Keyword.get(opts, :bundle_ref), lease, opts)

    updates = %{
      "lease" => lease,
      "lease_epoch" => lease["epoch"],
      "lease_owner" => lease["owner_id"],
      "status" => current_status(job_id)
    }

    case RedisStore.persist_terminal_job(job_id, updates, defaults) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:lease_persist_failed, reason}}
    end
  end

  defp current_status(job_id) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status}} when status in ["pending", "running", "paused"] -> status
      _ -> "pending"
    end
  end

  defp maybe_schedule_lease_renewal(state, true), do: schedule_lease_renewal(state)
  defp maybe_schedule_lease_renewal(state, false), do: state

  defp schedule_lease_renewal(state) do
    state = cancel_lease_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:renew_lease, token}, lease_renew_interval_ms())
    %{state | lease_timer_ref: timer_ref, lease_timer_token: token}
  end

  defp cancel_lease_timer(state) do
    ref = Map.get(state, :lease_timer_ref)
    token = Map.get(state, :lease_timer_token)

    if is_reference(ref) do
      Process.cancel_timer(ref)

      receive do
        {:renew_lease, ^token} -> :ok
      after
        0 -> :ok
      end
    end

    clear_lease_timer(state)
  end

  defp clear_lease_timer(state) do
    state
    |> Map.put(:lease_timer_ref, nil)
    |> Map.put(:lease_timer_token, nil)
  end

  defp config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil ->
        app_positive_integer(key, default)

      "" ->
        app_positive_integer(key, default)

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> app_positive_integer(key, default)
        end
    end
  end

  defp app_positive_integer(key, default) do
    case Application.get_env(:mirror_neuron, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp persist_runner_failure(
         job_id,
         manifest,
         bundle,
         manifest_ref,
         lease,
         opts,
         reason,
         failure_opts \\ []
       ) do
    reliability = reliability_from(manifest, opts)

    error =
      ErrorEnvelope.normalize(reason,
        component: "job_runner",
        code: "runtime.job_runner.failed",
        agent_id: "job_runner",
        node: to_string(Node.self())
      )

    defaults =
      %{
        "graph_id" => manifest.graph_id,
        "job_name" => manifest.job_name,
        "required_context_engine" => Map.get(manifest, :required_context_engine, false),
        "root_agent_ids" => manifest.entrypoints,
        "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
        "job_type" => scheduler_plan(manifest, opts)["job_type"],
        "scheduler" => scheduler_plan(manifest, opts),
        "requested_recovery_policy" => reliability["requested_recovery_policy"],
        "recovery_policy" => reliability["effective_recovery_policy"],
        "reliability_degraded" => reliability["reliability_degraded"],
        "reliability" => reliability_map(reliability),
        "manifest" => MirrorNeuron.Manifest.to_map(manifest),
        "manifest_ref" => manifest_ref || Runtime.bundle_ref(manifest, bundle),
        "deployment" => stringify_map(Keyword.get(opts, :deployment_context, %{})),
        "submitted_at" => Runtime.timestamp()
      }
      |> Map.merge(policy_fields(manifest, reliability, scheduler_plan(manifest, opts)))
      |> maybe_put_lease(lease)

    updates =
      %{
        "status" => "failed",
        "result" => %{
          "agent_id" => "job_runner",
          "error" => error,
          "reason" => ErrorEnvelope.desc(error),
          "status_reason" => ErrorEnvelope.desc(error)
        }
      }
      |> maybe_clear_lease(Keyword.get(failure_opts, :clear_lease?, false))

    case RedisStore.persist_terminal_job(job_id, updates, defaults) do
      {:ok, _job} ->
        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to persist job runner fallback state for #{job_id}: #{inspect(persist_reason)}"
        )
    end
  end

  defp maybe_clear_lease(updates, true) do
    Map.merge(updates, %{"lease" => nil, "lease_epoch" => nil, "lease_owner" => nil})
  end

  defp maybe_clear_lease(updates, false), do: updates

  defp job_defaults(manifest, manifest_ref, lease, opts) do
    reliability = reliability_from(manifest, opts)

    %{
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "required_context_engine" => Map.get(manifest, :required_context_engine, false),
      "root_agent_ids" => manifest.entrypoints,
      "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
      "job_type" => scheduler_plan(manifest, opts)["job_type"],
      "scheduler" => scheduler_plan(manifest, opts),
      "requested_recovery_policy" => reliability["requested_recovery_policy"],
      "recovery_policy" => reliability["effective_recovery_policy"],
      "reliability_degraded" => reliability["reliability_degraded"],
      "reliability" => reliability_map(reliability),
      "manifest" => MirrorNeuron.Manifest.to_map(manifest),
      "manifest_ref" => manifest_ref,
      "deployment" => stringify_map(Keyword.get(opts, :deployment_context, %{})),
      "submitted_at" => Runtime.timestamp()
    }
    |> Map.merge(policy_fields(manifest, reliability, scheduler_plan(manifest, opts)))
    |> maybe_put_lease(lease)
  end

  defp maybe_put_lease(map, nil), do: map

  defp maybe_put_lease(map, lease) do
    map
    |> Map.put("lease", lease)
    |> Map.put("lease_epoch", lease["epoch"])
    |> Map.put("lease_owner", lease["owner_id"])
  end

  defp reliability_from(manifest, opts) do
    requested =
      Keyword.get(opts, :requested_recovery_policy) ||
        Map.get(manifest.policies, "recovery_mode", "auto")

    effective =
      Keyword.get(opts, :recovery_policy) ||
        if(requested == "auto", do: "local_restart", else: requested)

    defaults = %{
      "mode" => "single_node",
      "requested_recovery_policy" => requested,
      "effective_recovery_policy" => effective,
      "reliability_degraded" => false,
      "degraded" => false,
      "reason" => "fallback runtime persistence",
      "observed_nodes" => [to_string(Node.self())],
      "observed_at" => Runtime.timestamp()
    }

    opts
    |> Keyword.get(:reliability, %{})
    |> normalize_reliability()
    |> then(&Map.merge(defaults, &1))
  end

  defp normalize_reliability(reliability) when is_map(reliability), do: reliability
  defp normalize_reliability(_reliability), do: %{}

  defp scheduler_plan(manifest, opts) do
    Keyword.get(opts, :scheduler_plan) ||
      %{
        "status" => "unknown",
        "job_type" => manifest.type || "batch",
        "strategy" => "unknown",
        "placements" => []
      }
  end

  defp reliability_map(reliability) do
    Map.take(reliability, [
      "mode",
      "effective_recovery_policy",
      "degraded",
      "reason",
      "observed_nodes",
      "observed_at"
    ])
  end

  defp policy_fields(manifest, reliability, scheduler_plan) do
    policies =
      LifecyclePolicy.normalize(
        manifest,
        scheduler_plan["job_type"],
        reliability["effective_recovery_policy"]
      )

    Map.put(policies, "policy_state", %{"agents" => %{}})
  end

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
