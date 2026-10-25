defmodule MirrorNeuron.Runner.ServiceLifecycle do
  @moduledoc false
  alias MirrorNeuron.Runner.WorkflowEnvironment

  def new(config, opts) do
    environment = Map.merge(config["environment"] || %{}, WorkflowEnvironment.from_options(opts))
    generation = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    receipt = %{
      "schema_version" => "mn.service.lifecycle.v1",
      "job_id" => text(environment["MN_JOB_ID"] || Keyword.get(opts, :job_id)),
      "execution_id" => text(environment["MN_RUN_ID"] || Keyword.get(opts, :job_id)),
      "run_id" => text(environment["MN_WORKFLOW_RUN_ID"] || Keyword.get(opts, :job_id)),
      "step_id" => text(environment["MN_WORKFLOW_STEP_ID"]),
      "service_id" => text(Keyword.get(opts, :agent_id)),
      "attempt_id" => text(environment["MN_WORKFLOW_ATTEMPT_ID"] || generation),
      "generation" => generation,
      "sequence" => 0
    }

    %{receipt: receipt, callback: Keyword.get(opts, :event_callback)}
  end

  def publish(%{receipt: %{"state" => state}} = lifecycle, state, _reason), do: lifecycle

  def publish(lifecycle, state, reason) do
    receipt =
      Map.merge(lifecycle.receipt, %{
        "state" => state,
        "reason" => reason,
        "sequence" => lifecycle.receipt["sequence"] + 1,
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
      })

    deliver(lifecycle.callback, %{
      "step_id" => receipt["step_id"],
      "agent_id" => receipt["service_id"],
      "status" => state,
      "message" => "Service is #{state}.",
      "details" => receipt
    })

    %{lifecycle | receipt: receipt}
  end

  defp deliver(callback, payload) when is_function(callback, 2) do
    _ = callback.("service_lifecycle", payload)
    :ok
  rescue
    _ -> :ok
  end

  defp deliver(_, _), do: :ok
  defp text(nil), do: ""
  defp text(value), do: to_string(value)
end
