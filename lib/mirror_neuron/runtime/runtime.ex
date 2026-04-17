defmodule MirrorNeuron.Runtime do
  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.{EventBus, JobRunner}

  def start_job(manifest, opts \\ []) do
    job_id = Keyword.get(opts, :job_id, generate_job_id(manifest.graph_id))
    bundle = Keyword.get(opts, :job_bundle)

    case persist_initial_job(job_id, manifest, bundle) do
      :ok ->
        spec = {JobRunner, {job_id, manifest, opts}}

        case Horde.DynamicSupervisor.start_child(MirrorNeuron.Runtime.JobSupervisor, spec) do
          {:ok, pid} ->
            {:ok, job_id, pid}

          {:error, reason} ->
            persist_startup_failure(job_id, manifest, bundle, reason)
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

  def await_completion(job_id, timeout) do
    wait_until_terminal(job_id, timeout, System.monotonic_time(:millisecond))
  end

  def deliver(job_id, agent_id, message) do
    deliver_with_retry(job_id, agent_id, message, 50)
  end

  defp call_job(job_id, message) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:job, job_id}) do
      [{pid, _}] -> GenServer.call(pid, message, 15_000)
      [] -> {:error, "job #{job_id} is not running in the connected cluster"}
    end
  end

  defp deliver_with_retry(job_id, agent_id, message, attempts_left) do
    case Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, {:agent, job_id, agent_id}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:deliver, message})
        :ok

      [] when attempts_left > 0 ->
        Process.sleep(50)
        deliver_with_retry(job_id, agent_id, message, attempts_left - 1)

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

  defp generate_job_id(graph_id) do
    suffix =
      6
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "#{graph_id}-#{System.system_time(:millisecond)}-#{suffix}"
  end

  def timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp persist_startup_failure(job_id, manifest, bundle, reason) do
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
      "root_agent_ids" => manifest.entrypoints,
      "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
      "recovery_policy" => Map.get(manifest.policies, "recovery_mode", "local_restart"),
      "manifest_ref" => %{
        "graph_id" => manifest.graph_id,
        "manifest_version" => manifest.manifest_version,
        "manifest_path" => bundle && bundle.manifest_path,
        "job_path" => bundle && bundle.root_path
      },
      "submitted_at" => timestamp()
    }

    RedisStore.persist_terminal_job(job_id, updates, defaults)
  end

  defp persist_initial_job(job_id, manifest, bundle) do
    job_map = %{
      "job_id" => job_id,
      "graph_id" => manifest.graph_id,
      "job_name" => manifest.job_name,
      "daemon" => manifest.daemon,
      "status" => "pending",
      "submitted_at" => timestamp(),
      "updated_at" => timestamp(),
      "root_agent_ids" => manifest.entrypoints,
      "placement_policy" => Map.get(manifest.policies, "placement_policy", "local"),
      "recovery_policy" => Map.get(manifest.policies, "recovery_mode", "local_restart"),
      "result" => nil,
      "manifest_ref" => %{
        "graph_id" => manifest.graph_id,
        "manifest_version" => manifest.manifest_version,
        "manifest_path" => bundle && bundle.manifest_path,
        "job_path" => bundle && bundle.root_path
      }
    }

    case RedisStore.persist_job(job_id, job_map) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
