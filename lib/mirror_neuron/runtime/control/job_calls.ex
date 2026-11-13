defmodule MirrorNeuron.Runtime.JobCalls do
  @moduledoc "Registry lookup and bounded GenServer calls with structured failure results."

  require Logger

  alias MirrorNeuron.Runtime.ControlErrors
  alias MirrorNeuron.Runtime.ControlSettings

  def call_job(job_id, message, opts \\ []) do
    case lookup_job(job_id) do
      {:ok, pid} -> safe_job_call(job_id, pid, message, opts)
      :missing -> {:error, {:job_not_running, job_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def lookup_job(job_id) do
    case safe_registry_lookup({:job, job_id}) do
      {:ok, [{pid, _meta} | _]} -> {:ok, pid}
      {:ok, []} -> :missing
      {:error, reason} -> {:error, {:job_registry_unavailable, job_id, reason}}
    end
  end

  def lookup_job_runner(job_id) do
    case safe_registry_lookup({:job_runner, job_id}) do
      {:ok, [{pid, _meta} | _]} -> {:ok, pid}
      {:ok, []} -> :missing
      {:error, reason} -> {:error, {:job_registry_unavailable, job_id, reason}}
    end
  end

  defp safe_job_call(job_id, pid, message, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, ControlSettings.job_call_timeout_ms())

    try do
      GenServer.call(pid, message, timeout_ms)
    catch
      :exit, reason ->
        error = normalize_job_call_exit(reason, job_id, timeout_ms)
        maybe_log_job_call_error(error, job_id, message)
        {:error, error}
    end
  end

  defp normalize_job_call_exit({:timeout, _call}, job_id, timeout_ms),
    do: {:job_call_timeout, job_id, timeout_ms}

  defp normalize_job_call_exit({:noproc, _call}, job_id, _timeout_ms),
    do: {:job_not_running, job_id}

  defp normalize_job_call_exit({:normal, _call}, job_id, _timeout_ms),
    do: {:job_not_running, job_id}

  defp normalize_job_call_exit(reason, job_id, _timeout_ms),
    do: {:job_call_failed, job_id, reason}

  defp maybe_log_job_call_error({:job_not_running, _reason_job_id}, _job_id, _message), do: :ok

  defp maybe_log_job_call_error(reason, job_id, message) do
    Logger.warning(
      "runtime job call failed",
      job_id: job_id,
      message: inspect(message),
      reason: ControlErrors.error_message(reason)
    )
  end

  def safe_registry_lookup(key) do
    try do
      {:ok, Horde.Registry.lookup(MirrorNeuron.DistributedRegistry, key)}
    rescue
      exception -> {:error, {exception.__struct__, Exception.message(exception)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
end
