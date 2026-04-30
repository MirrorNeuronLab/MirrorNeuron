defmodule MirrorNeuron.Runtime do
  require Logger

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ContextEnginePreflight
  alias MirrorNeuron.JobId
  alias MirrorNeuron.Runtime.{Backpressure, EventBus, JobRunner}

  def start_job(manifest, opts \\ []) do
    job_id = Keyword.get(opts, :job_id, generate_job_id(manifest.graph_id))
    bundle = Keyword.get(opts, :job_bundle)

    case ContextEnginePreflight.ensure_available(
           Map.get(manifest, :required_context_engine, false)
         ) do
      :ok ->
        start_job_after_preflight(job_id, manifest, opts, bundle)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_job_after_preflight(job_id, manifest, opts, bundle) do
    manifest_ref = bundle_ref(manifest, bundle)
    opts = Keyword.put(opts, :bundle_ref, manifest_ref)

    case persist_initial_job(job_id, manifest, manifest_ref) do
      :ok ->
        spec = {JobRunner, {job_id, manifest, opts}}

        case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
          {:ok, pid} ->
            {:ok, job_id, pid}

          {:error, reason} ->
            persist_startup_failure(job_id, manifest, manifest_ref, reason)
            {:error, "failed to start job runner: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "failed to persist initial job: #{inspect(reason)}"}
    end
  end

  def pause_job(job_id), do: call_job(job_id, :pause)
  def resume_job(job_id), do: call_job(job_id, :resume)
  def cancel_job(job_id), do: call_job(job_id, :cancel)

  def cleanup_jobs(opts \\ []) do
    force_all = Keyword.get(opts, :all, false)

    case MirrorNeuron.Persistence.RedisStore.list_jobs() do
      {:ok, jobs} ->
        deleted =
          jobs
          |> Enum.filter(fn job ->
            force_all or job["status"] in ["completed", "failed", "cancelled"]
          end)
          |> Enum.map(& &1["job_id"])
          |> Enum.map(fn job_id ->
            MirrorNeuron.Persistence.RedisStore.delete_job(job_id)
            job_id
          end)

        {:ok, %{deleted_count: length(deleted), deleted_jobs: deleted}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_message(job_id, agent_id, message) when is_map(message) do
    call_job(job_id, {:send_message, agent_id, message})
  end

  def pressure(job_id), do: call_job(job_id, :pressure)

  def await_completion(job_id, timeout) do
    wait_until_terminal(job_id, timeout, System.monotonic_time(:millisecond))
  end

  def deliver(job_id, agent_id, message, opts \\ []) do
    deliver_with_retry(job_id, agent_id, message, 50, opts)
  end

  defp call_job(job_id, message) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
      [{pid, _}] -> GenServer.call(pid, message, 15_000)
      [] -> {:error, "job #{job_id} is not running in the connected cluster"}
    end
  end

  defp deliver_with_retry(job_id, agent_id, message, attempts_left, opts) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) do
      [{pid, _}] ->
        case preflight_delivery(pid, job_id, agent_id, opts) do
          :ok ->
            GenServer.cast(pid, {:deliver, message})
            :ok

          {:error, {:backpressure, details}} = error ->
            EventBus.publish(job_id, %{
              type: :backpressure_rejected,
              agent_id: agent_id,
              payload: details,
              timestamp: timestamp()
            })

            error
        end

      [] when attempts_left > 0 ->
        Process.sleep(50)
        deliver_with_retry(job_id, agent_id, message, attempts_left - 1, opts)

      [] ->
        EventBus.publish(job_id, %{
          type: :dead_letter,
          agent_id: agent_id,
          message: message,
          timestamp: timestamp()
        })

        {:error, "agent #{agent_id} is not running for job #{job_id}"}
    end
  end

  defp preflight_delivery(pid, job_id, agent_id, opts) do
    queue_depth = Backpressure.process_queue_depth(pid)
    pressure = Backpressure.snapshot(agent_id, %{}, queue_depth, opts)

    cond do
      Backpressure.saturated?(pressure) ->
        {:error,
         {:backpressure,
          Backpressure.retry_later_reason(pressure, %{
            "job_id" => job_id,
            "agent_id" => agent_id,
            "dropped" => true
          })}}

      Backpressure.pressured?(pressure) ->
        EventBus.publish(job_id, %{
          type: :backpressure_state,
          agent_id: agent_id,
          payload: pressure,
          timestamp: timestamp()
        })

        :ok

      true ->
        :ok
    end
  end

  defp wait_until_terminal(job_id, timeout, started_at) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["completed", "failed", "cancelled"] ->
        {:ok, job}

      {:ok, _job} ->
        if timeout != :infinity and System.monotonic_time(:millisecond) - started_at > timeout do
          {:error, "timed out waiting for job #{job_id}"}
        else
          Process.sleep(100)
          wait_until_terminal(job_id, timeout, started_at)
        end

      {:error, _reason} ->
        if timeout != :infinity and System.monotonic_time(:millisecond) - started_at > timeout do
          {:error, "timed out waiting for job #{job_id}"}
        else
          Process.sleep(100)
          wait_until_terminal(job_id, timeout, started_at)
        end
    end
  end

  @doc false
  def generate_job_id(graph_id), do: JobId.generate(graph_id)

  @doc false
  def bundle_ref(manifest, bundle) do
    base_ref = %{
      "graph_id" => manifest.graph_id,
      "manifest_version" => manifest.manifest_version,
      "manifest_path" => bundle && bundle.manifest_path,
      "job_path" => bundle && bundle.root_path
    }

    case Archive.store(bundle) do
      {:ok, archive_ref} ->
        base_ref
        |> Map.put("bundle_fingerprint", archive_ref.fingerprint)
        |> Map.put("bundle_storage", archive_ref.storage)
        |> Map.put("bundle_bytes", archive_ref.total_bytes)
        |> Map.put("cache_path", Archive.cache_path(archive_ref.fingerprint))

      {:error, _reason} ->
        base_ref
    end
  end

  def timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp persist_startup_failure(job_id, manifest, manifest_ref, reason) do
    updates = %{
      "status" => "failed",
      "result" => %{
        "agent_id" => "job_runner",
        "error" => "failed to start job runner process",
        "reason" => inspect(reason)
      }
    }

    defaults = %{
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "required_context_engine" => required_context_engine(manifest),
      "root_agent_ids" => manifest.entrypoints,
      "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
      "recovery_policy" => Map.get(manifest.policies, "recovery_mode", "local_restart"),
      "manifest_ref" => manifest_ref,
      "submitted_at" => timestamp()
    }

    RedisStore.persist_terminal_job(job_id, updates, defaults)
  end

  defp persist_initial_job(job_id, manifest, manifest_ref) do
    job_map = %{
      "job_id" => job_id,
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "daemon" => manifest.daemon,
      "required_context_engine" => required_context_engine(manifest),
      "status" => "pending",
      "submitted_at" => timestamp(),
      "updated_at" => timestamp(),
      "root_agent_ids" => manifest.entrypoints,
      "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
      "recovery_policy" => Map.get(manifest.policies, "recovery_mode", "local_restart"),
      "result" => nil,
      "topology" => MirrorNeuron.Manifest.topology(manifest),
      "manifest_ref" => manifest_ref
    }

    case RedisStore.persist_job(job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_context_engine(manifest), do: Map.get(manifest, :required_context_engine, false)
end
