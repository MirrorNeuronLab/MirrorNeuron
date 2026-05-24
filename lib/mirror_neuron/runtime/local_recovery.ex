defmodule MirrorNeuron.Runtime.LocalRecovery do
  use GenServer
  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.{EventBus, JobRunner, RecoverySafety}

  @active_statuses ["pending", "running", "paused"]
  @default_startup_scan_delay_ms 500
  @default_scan_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def scan(opts \\ []) do
    scan(__MODULE__, opts)
  end

  def scan(server, opts) do
    GenServer.call(server, {:scan, opts}, 30_000)
  end

  def recover_unfinished_jobs(opts \\ []) do
    maybe_repair_recovery_indexes()

    with {:ok, jobs} <- RedisStore.list_jobs() do
      jobs
      |> Enum.filter(&(&1["status"] in @active_statuses))
      |> Enum.reduce(%{checked: 0, recovered: 0, paused: 0, skipped: 0, failed: 0, jobs: []}, fn
        job, acc ->
          result =
            case recover_job_map(job, opts) do
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
      Map.get(result, :removed_stale_agents, 0)
  end

  def recover_job(job_id, opts \\ []) when is_binary(job_id) do
    with {:ok, job} <- RedisStore.fetch_job(job_id) do
      recover_job_map(job, opts)
    end
  end

  @impl true
  def init(opts) do
    if enabled?() do
      Process.send_after(self(), :scan, Keyword.get(opts, :startup_delay_ms, startup_delay_ms()))
    end

    {:ok, %{scan_interval_ms: Keyword.get(opts, :scan_interval_ms, scan_interval_ms())}}
  end

  @impl true
  def handle_info(:scan, state) do
    _ = recover_unfinished_jobs(reason: "startup_or_periodic_scan")
    Process.send_after(self(), :scan, state.scan_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call({:scan, opts}, _from, state) do
    {:reply, recover_unfinished_jobs(opts), state}
  end

  defp recover_job_map(%{"job_id" => job_id, "status" => status} = job, opts)
       when status in @active_statuses do
    cond do
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

  defp recover_job_map(%{"job_id" => job_id, "status" => status}, _opts) do
    {:ok, %{job_id: job_id, action: :skipped, reason: "job is #{status}"}}
  end

  defp do_recover_job(job, opts) do
    job_id = job["job_id"]

    with {:ok, bundle} <- load_recovery_bundle(job),
         {:ok, agents} <- RedisStore.list_agents(job_id) do
      case recovery_decision(job, bundle.manifest, agents, opts) do
        {:auto, reason} ->
          mark_recovery(job, "auto_resuming", reason, requires_review?: false)
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

  defp start_recovered_job(job, bundle, event_type, reason) do
    job_id = job["job_id"]

    opts =
      [
        job_bundle: bundle,
        local_recovery: true,
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
