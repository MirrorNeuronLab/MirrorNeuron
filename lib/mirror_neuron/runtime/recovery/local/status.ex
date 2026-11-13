defmodule MirrorNeuron.Runtime.LocalRecovery.Status do
  @moduledoc "Persists local recovery status and retires paused service registrations."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.ServiceRegistry

  def maybe_mark_started(job, :local_recovery_auto_resumed, reason) do
    mark_recovery(job, "auto_resumed", reason, requires_review?: false)
  end

  def maybe_mark_started(_job, _event_type, _reason), do: :ok

  def mark_recovery(job, status, reason, opts) do
    now = Runtime.timestamp()
    requires_review? = Keyword.get(opts, :requires_review?, false)

    mode = job["recovery_mode"] || "clean_restart"

    recovery = %{
      "status" => status,
      "mode" => mode,
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
        "recovery_requires_review" => requires_review?,
        "recovery_mode" => mode
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
      "reliability" => job["reliability"],
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

  def deregister_job_services(job_id) when is_binary(job_id) and job_id != "" do
    case ServiceRegistry.deregister_job(job_id) do
      {:ok, _count} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "failed to deregister services for paused recovery job #{job_id}: #{inspect(reason)}"
        )
    end
  end

  def deregister_job_services(_job_id), do: :ok

  defp maybe_put_status(map, nil), do: map

  defp maybe_put_status(map, status), do: Map.put(map, "status", status)

  defp maybe_clear_result(map, true), do: Map.put(map, "result", nil)

  defp maybe_clear_result(map, _clear?), do: map
end
