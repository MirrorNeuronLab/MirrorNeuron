defmodule MirrorNeuron.Builtins.Executor.Artifacts do
  @moduledoc "Routes bounded output and resolves durable step results without rerunning completed work."

  alias MirrorNeuron.Builtins.Executor.Decoding
  alias MirrorNeuron.Builtins.Executor.Events
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Builtins.StepContract

  def routed_output_payload(result, default_payload, input_payload) do
    with {:ok, decoded} when is_map(decoded) <- Decoding.decoded_result_payload(result),
         true <- Decoding.sdk_step_result?(decoded) do
      decoded
      |> Map.take([
        "outputs",
        "artifacts",
        "metrics",
        "status",
        "workflow_step_id",
        "run_id",
        "runtime_step_mode"
      ])
      |> Map.put("agent_id", default_payload["agent_id"])
      |> propagate_step_metadata(input_payload)
    else
      _ -> default_payload
    end
  end

  defp propagate_step_metadata(payload, input) when is_map(input) do
    metadata = StepContract.reference_metadata(input)
    if map_size(metadata) > 0, do: Map.put(payload, "_mn_step", metadata), else: payload
  end

  defp propagate_step_metadata(payload, _default_payload), do: payload

  def bounded_default_payload(result, input, attempts, lease, config, context) do
    payload = %{
      "agent_id" => context.node.node_id,
      "sandbox" =>
        result
        |> Map.drop(["structured_result"])
        |> Map.merge(%{"attempts" => attempts, "lease" => lease})
    }

    opts = staging_opts(config, context)

    case StagedArtifact.maybe_stage_output(payload, opts) do
      {:ok, ^payload, nil} ->
        {:ok, propagate_step_metadata(payload, input)}

      {:ok, staged_output, reference} ->
        {:ok,
         %{
           "agent_id" => context.node.node_id,
           "outputs" => staged_output,
           "artifacts" => [reference],
           "status" => "completed"
         }
         |> propagate_step_metadata(input)}

      {:error, _reason} = error ->
        error
    end
  end

  defp staging_opts(config, context) do
    environment = Map.get(config, "environment", %{})
    workflow = Map.get(context, :workflow, %{})

    [
      kind: "executor_result",
      submission_path: Map.get(environment, "MN_JOB_SHARED_STORAGE_ROOT"),
      submission_id: Map.get(environment, "MN_STORAGE_SUBMISSION_ID"),
      run_id: Map.get(workflow, "run_id") || context.job_id
    ]
  end

  def with_step_result_pointer(config, context, attempt) do
    environment = Map.get(config, "environment", %{})
    submission_path = Map.get(environment, "MN_JOB_SHARED_STORAGE_ROOT")

    if sdk_step_runtime?(config) and is_binary(submission_path) and submission_path != "" do
      workflow = Map.get(context, :workflow, %{})
      run_id = Map.get(workflow, "run_id") || context.job_id || "run"
      attempt_id = Map.get(workflow, "attempt_id") || "attempt-#{attempt}"

      pointer =
        Path.join([
          submission_path,
          "outputs",
          "runs",
          safe_component(run_id),
          "artifacts",
          "results",
          safe_component(context.node.node_id),
          safe_component(attempt_id) <> "-#{attempt}.json"
        ])

      Map.put(config, "environment", Map.put(environment, "MN_STEP_RESULT_FILE", pointer))
    else
      config
    end
  end

  defp sdk_step_runtime?(config) do
    case Map.get(config, "command") do
      command when is_binary(command) ->
        String.contains?(command, "mn_sdk.step_runtime")

      command when is_list(command) ->
        Enum.any?(command, &String.contains?(to_string(&1), "mn_sdk.step_runtime"))

      _ ->
        false
    end
  end

  def await_structured_result(result, config, context, waiting? \\ false) do
    case attach_structured_result(result, config) do
      {:error, %{"code" => "artifact_not_ready"}} ->
        unless waiting?, do: Events.report_event(context, :executor_artifact_waiting, %{})
        # The runner already finished. Wait for replication without invoking it
        # again or consuming execution retries. Independent cancellation and
        # delivery lease renewal remain active while this handler waits.
        Process.sleep(250)
        await_structured_result(result, config, context, true)

      outcome ->
        outcome
    end
  end

  defp attach_structured_result(%{"structured_result" => _} = result, _config), do: {:ok, result}

  defp attach_structured_result(result, config) do
    environment = Map.get(config, "environment", %{})

    case Map.get(environment, "MN_STEP_RESULT_FILE") do
      path when is_binary(path) and path != "" ->
        try do
          resolved =
            StagedArtifact.resolve_pointer!(path,
              submission_path: Map.get(environment, "MN_JOB_SHARED_STORAGE_ROOT")
            )

          {:ok, Map.put(result, "structured_result", resolved)}
        rescue
          error in StagedArtifact.NotReadyError ->
            {:error,
             %{
               "error" => Exception.message(error),
               "code" => error.code,
               "retryable" => error.retryable
             }}

          error in StagedArtifact.IntegrityError ->
            {:error, %{"error" => Exception.message(error), "code" => "artifact_integrity_error"}}
        end

      _ ->
        {:ok, result}
    end
  end

  defp safe_component(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim(".-")
    |> case do
      "" -> "run"
      normalized -> normalized
    end
  end
end
