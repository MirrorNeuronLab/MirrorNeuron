defmodule MirrorNeuron.Runtime.DeploymentController.Health do
  @moduledoc "Waits for a started deployment job within its healthy deadline."

  alias MirrorNeuron.Persistence.RedisStore

  def wait_for_started_job(job_id, policy) do
    timeout_ms = max(policy["healthy_deadline_ms"] || 0, 1_000)
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_started_job(job_id, started_at, timeout_ms)
  end

  defp do_wait_for_started_job(job_id, started_at, timeout_ms) do
    case RedisStore.fetch_job(job_id) do
      {:ok, %{"status" => status} = job} when status in ["running", "completed"] ->
        {:ok, job}

      {:ok, %{"status" => status} = job} when status in ["failed", "cancelled"] ->
        {:error, "deployment job #{job_id} reached #{status}: #{inspect(job["result"])}"}

      {:ok, _job} ->
        if System.monotonic_time(:millisecond) - started_at >= timeout_ms do
          {:error, "deployment job #{job_id} did not become ready within #{timeout_ms}ms"}
        else
          Process.sleep(100)
          do_wait_for_started_job(job_id, started_at, timeout_ms)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
