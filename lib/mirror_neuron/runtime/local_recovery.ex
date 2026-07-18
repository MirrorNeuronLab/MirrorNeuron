defmodule MirrorNeuron.Runtime.LocalRecovery do
  use GenServer
  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.{DiskCheckpoint, RedisStore}
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{EventBus, JobRunner, RecoverySafety}

  @active_statuses ["pending", "running", "paused"]
  @terminal_statuses ["completed", "failed", "cancelled"]
  @nonrecoverable_statuses @terminal_statuses ++ ["cancelling"]
  @default_startup_scan_delay_ms 500
  @default_scan_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def scan(opts \\ []) do
    scan(__MODULE__, opts)
  end

  def scan(server, opts) do
    GenServer.call(server, {:scan, opts}, 30_000)
  end

  def recover_unfinished_jobs(opts \\ []) do
    restore_disk_checkpoints()

    if Keyword.get(opts, :repair_indexes?, true) do
      maybe_repair_recovery_indexes()
    end

    with {:ok, jobs} <- RedisStore.list_job_summaries() do
      jobs
      |> Enum.filter(&recoverable_job_status?/1)
      |> Enum.reduce(%{checked: 0, recovered: 0, paused: 0, skipped: 0, failed: 0, jobs: []}, fn
        job, acc ->
          result =
            case fetch_and_recover_job(job, opts) do
              {:ok, value} -> value
              {:error, reason} -> %{job_id: job["job_id"], action: :failed, reason: reason}
            end

          acc
          |> bump(result.action)
          |> Map.update!(:checked, &(&1 + 1))
          |> Map.update!(:jobs, &[result | &1])
      end)
      |> Map.update!(:jobs, &Enum.reverse/1)
      |> then(&{:ok, &1})
    end
  end

  defp restore_disk_checkpoints do
    case DiskCheckpoint.list_jobs() do
      {:ok, %{checkpoints: checkpoints, errors: errors}} ->
        Enum.each(errors, fn {path, reason} ->
          Logger.warning("could not read disk checkpoint #{path}: #{inspect(reason)}")
        end)

        Enum.each(checkpoints, &restore_disk_checkpoint/1)
        :ok

      {:error, reason} ->
        Logger.warning("could not scan disk checkpoints: #{inspect(reason)}")
        :ok
    end
  end

  defp restore_disk_checkpoint(%{job: %{"job_id" => job_id} = disk_job, agents: agents}) do
    cond do
      disk_job["status"] in @nonrecoverable_statuses ->
        _ = DiskCheckpoint.delete_job(job_id)

      true ->
        case RedisStore.fetch_job(job_id) do
          {:ok, %{"status" => status}} when status in @nonrecoverable_statuses ->
            _ = DiskCheckpoint.delete_job(job_id)

          {:ok, redis_job} ->
            maybe_restore_job(job_id, disk_job, redis_job)
            restore_disk_agents(job_id, agents)

          {:error, reason} ->
            if not_found?(reason) do
              maybe_restore_job(job_id, disk_job, nil)
              restore_disk_agents(job_id, agents)
            else
              Logger.warning(
                "could not compare disk checkpoint for #{job_id} with Redis: #{inspect(reason)}"
              )
            end
        end
    end
  end

  defp restore_disk_checkpoint(_checkpoint), do: :ok

  defp maybe_restore_job(job_id, disk_job, nil) do
    case RedisStore.persist_job(job_id, disk_job) do
      {:ok, _job} -> :ok
      {:error, reason} -> log_restore_failure(job_id, "job", reason)
    end
  end

  defp maybe_restore_job(job_id, disk_job, redis_job) do
    if newer?(disk_job["updated_at"], redis_job["updated_at"]) do
      maybe_restore_job(job_id, disk_job, nil)
    else
      :ok
    end
  end

  defp restore_disk_agents(job_id, agents) do
    Enum.each(agents, fn agent ->
      case recovery_agent_id(agent) do
        {:ok, agent_id} ->
          restore_disk_agent(job_id, agent_id, agent)

        :error ->
          Logger.warning(
            "ignoring disk agent checkpoint without an agent_id or node_id for #{job_id}"
          )
      end
    end)
  end

  defp restore_disk_agent(job_id, agent_id, agent) do
    case RedisStore.fetch_agent(job_id, agent_id) do
      {:ok, redis_agent} ->
        if newer?(agent["last_heartbeat_at"], redis_agent["last_heartbeat_at"]) do
          persist_restored_agent(job_id, agent_id, agent)
        end

      {:error, reason} ->
        if not_found?(reason) do
          persist_restored_agent(job_id, agent_id, agent)
        else
          log_restore_failure(job_id, "agent #{agent_id}", reason)
        end
    end
  end

  defp recovery_agent_id(agent) do
    case agent["agent_id"] || agent["node_id"] do
      agent_id when is_binary(agent_id) and agent_id != "" -> {:ok, agent_id}
      _agent_id -> :error
    end
  end

  defp persist_restored_agent(job_id, agent_id, agent) do
    case RedisStore.persist_agent(job_id, agent_id, agent) do
      {:ok, _agent} -> :ok
      {:error, reason} -> log_restore_failure(job_id, "agent #{agent_id}", reason)
    end
  end

  defp newer?(left, right) when is_binary(left) and is_binary(right), do: left > right
  defp newer?(left, _right) when is_binary(left), do: true
  defp newer?(_left, _right), do: false

  defp not_found?(reason) when is_binary(reason), do: String.contains?(reason, "was not found")
  defp not_found?(_reason), do: false

  defp log_restore_failure(job_id, checkpoint, reason) do
    Logger.warning(
      "could not restore disk #{checkpoint} checkpoint for #{job_id}: #{inspect(reason)}"
    )
  end

  defp fetch_and_recover_job(%{"job_id" => job_id}, opts) when is_binary(job_id) do
    with {:ok, job} <- RedisStore.fetch_job(job_id) do
      recover_job_map(job, opts)
    end
  end

  defp fetch_and_recover_job(job, opts), do: recover_job_map(job, opts)

  defp maybe_repair_recovery_indexes do
    case RedisStore.repair_recovery_indexes() do
      {:ok, result} ->
        if recovery_index_repairs(result) > 0 do
          Logger.info("repaired MirrorNeuron recovery indexes: #{inspect(result)}")
        end

        :ok

      {:error, reason} ->
        Logger.warning("failed to repair MirrorNeuron recovery indexes: #{inspect(reason)}")
        :ok
    end
  end

  defp recovery_index_repairs(result) do
    Map.get(result, :repaired_jobs, 0) +
      Map.get(result, :repaired_agents, 0) +
      Map.get(result, :removed_stale_jobs, 0) +
      Map.get(result, :removed_stale_agents, 0) +
      Map.get(result, :repaired_recovery_evals, 0) +
      Map.get(result, :removed_stale_recovery_evals, 0)
  end

  def recover_job(job_id, opts \\ []) when is_binary(job_id) do
    with {:ok, job} <- RedisStore.fetch_job(job_id) do
      recover_job_map(job, opts)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      scan_interval_ms: Keyword.get(opts, :scan_interval_ms, scan_interval_ms()),
      repair_indexes_on_next_scan: true,
      scan_timer_ref: nil,
      scan_token: nil
    }

    state =
      if enabled?() do
        schedule_scan(state, Keyword.get(opts, :startup_delay_ms, startup_delay_ms()))
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:scan, token}, %{scan_token: token} = state) do
    state = clear_scan_timer(state)
    state = run_periodic_scan(state)
    {:noreply, schedule_scan(state, state.scan_interval_ms)}
  end

  def handle_info({:scan, _stale_token}, state), do: {:noreply, state}

  def handle_info(:scan, state), do: {:noreply, run_periodic_scan(state)}

  @impl true
  def terminate(_reason, state) do
    cancel_scan_timer(state)
    :ok
  end

  defp run_periodic_scan(state) do
    _ =
      recover_unfinished_jobs(
        reason: "startup_or_periodic_scan",
        repair_indexes?: state.repair_indexes_on_next_scan
      )

    %{state | repair_indexes_on_next_scan: false}
  end

  @impl true
  def handle_call({:scan, opts}, _from, state) do
    {:reply, recover_unfinished_jobs(opts), state}
  end

  defp schedule_scan(state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    state = cancel_scan_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:scan, token}, delay_ms)
    %{state | scan_timer_ref: timer_ref, scan_token: token}
  end

  defp schedule_scan(state, _delay_ms), do: cancel_scan_timer(state)

  defp cancel_scan_timer(%{scan_timer_ref: ref, scan_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:scan, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_scan_timer(state)
  end

  defp cancel_scan_timer(state), do: state

  defp clear_scan_timer(state),
    do: %{state | scan_timer_ref: nil, scan_token: nil}

  defp recover_job_map(%{"job_id" => job_id, "status" => status} = job, opts) do
    cond do
      paused_for_review?(job) and not Keyword.get(opts, :manual_resume, false) ->
        {:ok, %{job_id: job_id, action: :skipped, reason: "job is paused for review"}}

      not recoverable_job_status?(job) ->
        {:ok, %{job_id: job_id, action: :skipped, reason: "job is #{status}"}}

      job_runner_alive?(job_id) ->
        {:ok, %{job_id: job_id, action: :already_running, reason: "job runner is live"}}

      active_lease?(job_id) and not Keyword.get(opts, :ignore_lease, false) ->
        {:ok, %{job_id: job_id, action: :skipped, reason: "job lease is still active"}}

      cluster_recoverable_policy?(job) and not Keyword.get(opts, :manual_resume, false) ->
        {:ok,
         %{
           job_id: job_id,
           action: :skipped,
           reason: "job is configured for cluster recovery"
         }}

      true ->
        do_recover_job(job, opts)
    end
  end

  defp recover_job_map(%{"job_id" => job_id}, _opts),
    do: {:ok, %{job_id: job_id, action: :skipped, reason: "job status is unknown"}}

  defp paused_for_review?(job) do
    Map.get(job, "recovery_status") == "paused_for_review" or
      get_in(job, ["recovery", "status"]) == "paused_for_review" or
      Map.get(job, "recovery_requires_review") == true
  end

  defp do_recover_job(job, opts) do
    job_id = job["job_id"]

    with {:ok, bundle} <- load_recovery_bundle(job),
         {:ok, agents} <- RedisStore.list_agents(job_id) do
      case recovery_decision(job, bundle.manifest, agents, opts) do
        {:auto, reason} ->
          mark_recovery(
            job,
            "auto_resuming",
            reason,
            auto_resume_mark_options(job)
          )

          start_recovered_job(job, bundle, :local_recovery_auto_resumed, reason)

        {:manual, reason} ->
          mark_recovery(job, "paused_for_review", reason,
            requires_review?: true,
            status: "paused"
          )

          start_recovered_job(job, bundle, :local_recovery_paused_for_review, reason)
          |> normalize_manual_result()

        {:blocked, reason} ->
          mark_recovery(job, "paused_for_review", reason,
            requires_review?: true,
            status: "paused"
          )

          EventBus.publish(job_id, %{
            type: :local_recovery_paused_for_review,
            reason: reason,
            blocked: true,
            timestamp: Runtime.timestamp()
          })

          {:ok, %{job_id: job_id, action: :paused_for_review, reason: reason, blocked: true}}
      end
    else
      {:error, reason} ->
        mark_recovery(job, "paused_for_review", inspect(reason),
          requires_review?: true,
          status: "paused"
        )

        EventBus.publish(job_id, %{
          type: :local_recovery_paused_for_review,
          reason: inspect(reason),
          blocked: true,
          timestamp: Runtime.timestamp()
        })

        {:error, "could not prepare local recovery for #{job_id}: #{inspect(reason)}"}
    end
  end

  defp normalize_manual_result({:ok, %{action: :started} = result}),
    do: {:ok, %{result | action: :paused_for_review}}

  defp normalize_manual_result(other), do: other

  defp recovery_decision(job, manifest, agents, opts) do
    RecoverySafety.decision(job, manifest, agents, opts)
  end

  defp recoverable_job_status?(%{"status" => status} = job) do
    status in @active_statuses or recoverable_runner_interruption?(job) or
      runner_interruption_recovery_hint?(job)
  end

  defp recoverable_job_status?(_job), do: false

  defp runner_interruption_recovery_hint?(%{
         "status" => "failed",
         "recovery_hint" => "runner_interruption"
       }),
       do: true

  defp runner_interruption_recovery_hint?(_job), do: false

  defp recoverable_runner_interruption?(%{
         "status" => "failed",
         "result" => %{
           "agent_id" => "job_runner",
           "error" => "job coordinator exited before terminal state"
         }
       }),
       do: true

  defp recoverable_runner_interruption?(_job), do: false

  defp auto_resume_mark_options(job) do
    if recoverable_runner_interruption?(job) do
      [requires_review?: false, status: "running", clear_result?: true]
    else
      [requires_review?: false]
    end
  end

  defp start_recovered_job(job, bundle, event_type, reason) do
    job_id = job["job_id"]

    opts =
      [
        job_bundle: bundle,
        local_recovery: true,
        preferred_start_node: to_string(Node.self()),
        requested_recovery_policy: job["requested_recovery_policy"],
        recovery_policy: job["recovery_policy"],
        reliability: job["reliability"]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    spec = {JobRunner, {job_id, bundle.manifest, opts}}

    case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
      {:ok, _pid} ->
        maybe_mark_started(job, event_type, reason)

        EventBus.publish(job_id, %{
          type: event_type,
          reason: reason,
          timestamp: Runtime.timestamp()
        })

        {:ok, %{job_id: job_id, action: :started, reason: reason}}

      {:error, {:already_started, _pid}} ->
        {:ok, %{job_id: job_id, action: :already_running, reason: "job runner is live"}}

      {:error, reason} ->
        mark_recovery(job, "paused_for_review", inspect(reason),
          requires_review?: true,
          status: "paused"
        )

        {:error, "failed to start local recovery for #{job_id}: #{inspect(reason)}"}
    end
  end

  defp maybe_mark_started(job, :local_recovery_auto_resumed, reason) do
    mark_recovery(job, "auto_resumed", reason, requires_review?: false)
  end

  defp maybe_mark_started(_job, _event_type, _reason), do: :ok

  defp load_recovery_bundle(job) do
    manifest_ref = job["manifest_ref"] || %{}
    fingerprint = manifest_ref["bundle_fingerprint"] || manifest_ref[:bundle_fingerprint]
    job_path = manifest_ref["job_path"] || manifest_ref[:job_path]

    cond do
      is_binary(fingerprint) and fingerprint != "" ->
        case Archive.load(fingerprint) do
          {:ok, bundle} -> {:ok, bundle}
          {:error, _reason} when is_binary(job_path) -> JobBundle.load_filesystem_path(job_path)
          {:error, _reason} -> load_embedded_manifest(job)
        end

      is_binary(job_path) ->
        JobBundle.load_filesystem_path(job_path)

      true ->
        load_embedded_manifest(job)
    end
  end

  defp load_embedded_manifest(%{"manifest" => manifest}) when is_map(manifest) do
    JobBundle.load(manifest)
  end

  defp load_embedded_manifest(_job), do: {:error, :missing_recovery_manifest}

  defp mark_recovery(job, status, reason, opts) do
    now = Runtime.timestamp()
    requires_review? = Keyword.get(opts, :requires_review?, false)

    recovery = %{
      "status" => status,
      "reason" => reason,
      "requires_review" => requires_review?,
      "can_resume" => requires_review?,
      "updated_at" => now
    }

    updates =
      %{
        "recovery" => recovery,
        "recovery_status" => status,
        "recovery_reason" => reason,
        "recovery_requires_review" => requires_review?
      }
      |> maybe_put_status(Keyword.get(opts, :status))
      |> maybe_clear_result(Keyword.get(opts, :clear_result?, false))

    defaults = %{
      "job_id" => job["job_id"],
      "graph_id" => job["graph_id"] || "unknown",
      "job_name" => job["job_name"] || job["graph_id"] || "unknown",
      "root_agent_ids" => job["root_agent_ids"] || [],
      "placement_policy" => job["placement_policy"] || "local",
      "requested_recovery_policy" => job["requested_recovery_policy"] || "auto",
      "recovery_policy" => job["recovery_policy"] || "local_restart",
      "reliability_degraded" => job["reliability_degraded"] || false,
      "reliability" => job["reliability"] || legacy_reliability(job),
      "manifest" => job["manifest"],
      "manifest_ref" => job["manifest_ref"] || %{},
      "submitted_at" => job["submitted_at"] || now
    }

    case RedisStore.persist_terminal_job(job["job_id"], updates, defaults) do
      {:ok, _job} ->
        :ok

      {:error, persist_reason} ->
        Logger.warning(
          "failed to persist local recovery status for #{job["job_id"]}: #{inspect(persist_reason)}"
        )
    end
  end

  defp maybe_put_status(map, nil), do: map
  defp maybe_put_status(map, status), do: Map.put(map, "status", status)
  defp maybe_clear_result(map, true), do: Map.put(map, "result", nil)
  defp maybe_clear_result(map, _clear?), do: map

  defp cluster_recoverable_policy?(job) do
    Map.get(job, "recovery_policy", "local_restart") == "cluster_recover"
  end

  defp legacy_reliability(job) do
    %{
      "mode" => "single_node",
      "effective_recovery_policy" => job["recovery_policy"] || "local_restart",
      "degraded" => job["reliability_degraded"] || false,
      "reason" => "legacy job without reliability metadata",
      "observed_nodes" => [to_string(Node.self())],
      "observed_at" => Runtime.timestamp()
    }
  end

  defp active_lease?(job_id) do
    case RedisStore.get_lease("job:#{job_id}") do
      {:ok, nil} -> false
      {:ok, _lease} -> true
      {:error, _reason} -> true
    end
  end

  defp job_runner_alive?(job_id) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job_runner, job_id}) do
      [{pid, _meta}] -> pid_alive?(pid)
      _ -> false
    end
  end

  defp pid_alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)

  defp pid_alive?(pid) when is_pid(pid) do
    case :rpc.call(node(pid), Process, :alive?, [pid], 5_000) do
      true -> true
      _ -> false
    end
  end

  defp pid_alive?(_pid), do: false

  defp bump(acc, :started), do: Map.update!(acc, :recovered, &(&1 + 1))
  defp bump(acc, :paused_for_review), do: Map.update!(acc, :paused, &(&1 + 1))
  defp bump(acc, :failed), do: Map.update!(acc, :failed, &(&1 + 1))
  defp bump(acc, _action), do: Map.update!(acc, :skipped, &(&1 + 1))

  defp enabled? do
    env_enabled?("MN_LOCAL_RECOVERY_ENABLED", :local_recovery_enabled, true)
  end

  defp startup_delay_ms do
    config_integer(
      "MN_LOCAL_RECOVERY_STARTUP_DELAY_MS",
      :local_recovery_startup_delay_ms,
      @default_startup_scan_delay_ms
    )
  end

  defp scan_interval_ms do
    config_integer(
      "MN_LOCAL_RECOVERY_SCAN_INTERVAL_MS",
      :local_recovery_scan_interval_ms,
      @default_scan_interval_ms
    )
  end

  defp config_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> Application.get_env(:mirror_neuron, key, default)
      value -> parse_non_negative_integer(value, default)
    end
  end

  defp parse_non_negative_integer(value, default) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp env_enabled?(env_name, key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key, default)
      "" -> false
      value -> value not in ["0", "false", "FALSE", "False", "no", "NO"]
    end
  end
end
