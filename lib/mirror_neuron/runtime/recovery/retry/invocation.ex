defmodule MirrorNeuron.Runtime.RunRetry.Invocation do
  @moduledoc "Refreshes retry execution context only while its running attempt lease remains valid."

  alias MirrorNeuron.Runtime.RunRetry.Configuration
  alias MirrorNeuron.Persistence.RedisStore

  def invocation_config(config, context) do
    environment = config["environment"] || %{}

    if environment["MN_RUN_RETRY_JSON"] do
      with true <- is_integer(context.lease_epoch) and context.lease_epoch > 0,
           {:ok, job} <- RedisStore.fetch_job(context.job_id),
           :ok <- RedisStore.validate_job_attempt_epoch(context.job_id, context.lease_epoch),
           true <- job["status"] == "running" and is_map(job["retry_request"]) do
        clock = job["running_time"] || %{}

        retry = %{
          "configuration_overrides" => Configuration.effective_overrides(job),
          "consumed_seconds" => (clock["accumulated_ms"] || 0) / 1000,
          "active_since" => clock["active_since"],
          "attempt" => job["attempt"]
        }

        {:ok,
         Map.put(
           config,
           "environment",
           Map.put(environment, "MN_RUN_RETRY_JSON", Jason.encode!(retry))
         )}
      else
        _ ->
          {:error,
           %{
             "error" => "Retry execution no longer has a verified running lease.",
             "retryable" => false
           }}
      end
    else
      {:ok, config}
    end
  end
end
