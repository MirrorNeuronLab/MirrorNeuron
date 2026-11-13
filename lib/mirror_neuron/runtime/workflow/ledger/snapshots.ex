defmodule MirrorNeuron.Runtime.WorkflowLedger.Snapshots do
  @moduledoc "Compacts workflow state and stages large persisted messages and outputs."

  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Runtime.ChildWorkflow
  alias MirrorNeuron.Runtime.WorkflowLedger.State

  def compact_snapshot(%{"steps" => steps} = state) when is_map(steps) do
    compact_steps =
      Map.new(steps, fn {step_id, step} ->
        value =
          if is_map(step) do
            step
            |> Map.drop(["last_message", "output", "instance_input"])
            |> maybe_put_output_ref(Map.get(step, "output"))
          else
            step
          end

        {step_id, value}
      end)

    state
    |> Map.drop(["messages"])
    |> Map.put("steps", compact_steps)
    |> ChildWorkflow.public_snapshot()
  end

  def compact_snapshot(state), do: state

  def persistable_snapshot(%{"steps" => steps} = state, manifest) when is_map(steps) do
    persisted_steps =
      Map.new(steps, fn {step_id, step} ->
        value =
          if is_map(step) do
            step
            |> persist_step_value("output", "output_ref", "step_output", state, manifest)
            |> persist_step_value(
              "last_message",
              "last_message_ref",
              "workflow_message",
              state,
              manifest
            )
          else
            step
          end

        {step_id, value}
      end)

    Map.put(state, "steps", persisted_steps)
  end

  def persistable_snapshot(state, _manifest), do: state

  defp persist_step_value(step, field, reference_field, kind, state, manifest) do
    case Map.get(step, field) do
      nil ->
        step

      value ->
        reference =
          StagedArtifact.output_ref(value) ||
            stage_ledger_value(value, kind, state, manifest)

        cond do
          is_map(reference) ->
            step
            |> Map.delete(field)
            |> Map.put(reference_field, reference)

          StagedArtifact.inline_value?(value) ->
            step

          true ->
            step
            |> Map.delete(field)
            |> Map.put(reference_field <> "_error", %{
              "code" => "artifact_staging_failed",
              "retryable" => true
            })
        end
    end
  end

  defp stage_ledger_value(value, kind, state, manifest) do
    case StagedArtifact.stage_from_manifest(value, manifest,
           kind: kind,
           run_id: State.run_id(state) || Map.get(state, "job_id") || "run"
         ) do
      {:ok, reference} -> reference
      {:error, _reason} -> nil
    end
  end

  defp maybe_put_output_ref(step, output) do
    case Map.get(step, "output_ref") || StagedArtifact.output_ref(output) do
      reference when is_map(reference) -> Map.put(step, "output_ref", reference)
      _ -> step
    end
  end

  def last_message_present?(step) when is_map(step) do
    is_map(Map.get(step, "last_message")) or
      StagedArtifact.ref?(Map.get(step, "last_message_ref"))
  end

  def step_last_message(step) when is_map(step) do
    case Map.get(step, "last_message") do
      message when is_map(message) -> message
      _ -> resolve_reference(Map.get(step, "last_message_ref"))
    end
  end

  def step_last_message(_step), do: nil

  def step_output(step) when is_map(step) do
    case Map.get(step, "output") do
      nil -> resolve_reference(Map.get(step, "output_ref"))
      output -> StagedArtifact.resolve_output!(output)
    end
  end

  defp resolve_reference(reference) do
    if StagedArtifact.ref?(reference), do: StagedArtifact.resolve!(reference), else: nil
  end
end
