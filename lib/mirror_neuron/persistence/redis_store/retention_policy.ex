defmodule MirrorNeuron.Persistence.RedisStore.RetentionPolicy do
  @moduledoc "Retention configuration and terminal-record eligibility predicates."

  alias MirrorNeuron.Persistence.RedisStore.Values

  @terminal_statuses ["completed", "failed", "cancelled"]
  @default_terminal_job_ttl_seconds 7 * 24 * 60 * 60
  @default_event_ttl_seconds 7 * 24 * 60 * 60
  @default_event_max_count 10_000
  @default_agent_snapshot_ttl_seconds 7 * 24 * 60 * 60
  @default_bundle_archive_ttl_seconds 7 * 24 * 60 * 60
  @default_blob_ref_ttl_seconds 7 * 24 * 60 * 60
  @default_recovery_eval_ttl_seconds 24 * 60 * 60

  def maybe_expire_key_command(_redis_key, ttl_seconds)
      when not is_integer(ttl_seconds) or ttl_seconds <= 0,
      do: []

  def maybe_expire_key_command(redis_key, ttl_seconds),
    do: [["EXPIRE", redis_key, to_string(ttl_seconds)]]

  def terminal_job_expired?(_job, ttl_seconds) when ttl_seconds < 0, do: false

  def terminal_job_expired?(job, ttl_seconds) do
    not retained_retry_state?(job) and
      terminal_status?(Map.get(job, "status")) and job_age_seconds(job) >= ttl_seconds
  end

  def retained_retry_state?(job) do
    receipts = Values.field(job, "retry_receipts")

    Values.field(job, "retry_checkpoint_discarded") != true and
      (Values.field(job, "status") == "failed" or (is_map(receipts) and map_size(receipts) > 0))
  end

  def terminal_status?(status), do: status in @terminal_statuses

  defp job_age_seconds(job) do
    updated_at = Map.get(job, "updated_at") || Map.get(job, "submitted_at") || Values.timestamp()

    with true <- is_binary(updated_at),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(updated_at) do
      DateTime.diff(DateTime.utc_now(), datetime, :second)
    else
      _ -> 0
    end
  end

  def terminal_job_ttl_seconds do
    Values.config_integer(
      "MN_TERMINAL_JOB_TTL_SECONDS",
      :terminal_job_ttl_seconds,
      @default_terminal_job_ttl_seconds
    )
  end

  def event_ttl_seconds do
    Values.config_integer(
      "MN_EVENT_TTL_SECONDS",
      :event_ttl_seconds,
      @default_event_ttl_seconds
    )
  end

  def event_max_count do
    Values.config_integer("MN_EVENT_MAX_COUNT", :event_max_count, @default_event_max_count)
  end

  def agent_snapshot_ttl_seconds do
    Values.config_integer(
      "MN_AGENT_SNAPSHOT_TTL_SECONDS",
      :agent_snapshot_ttl_seconds,
      @default_agent_snapshot_ttl_seconds
    )
  end

  def bundle_archive_ttl_seconds do
    Values.config_integer(
      "MN_BUNDLE_ARCHIVE_TTL_SECONDS",
      :bundle_archive_ttl_seconds,
      @default_bundle_archive_ttl_seconds
    )
  end

  def blob_ref_ttl_seconds do
    Values.config_integer(
      "MN_BLOB_REF_TTL_SECONDS",
      :blob_ref_ttl_seconds,
      @default_blob_ref_ttl_seconds
    )
  end

  def recovery_eval_ttl_seconds do
    Values.config_integer(
      "MN_RECOVERY_EVAL_TTL_SECONDS",
      :recovery_eval_ttl_seconds,
      @default_recovery_eval_ttl_seconds
    )
  end
end
