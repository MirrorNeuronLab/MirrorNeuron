defmodule MirrorNeuron.Runtime.WorkflowAdmission do
  @moduledoc "Attaches the owning ledger attempt before a workflow handler executes."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Runtime.ChildWorkflow
  alias MirrorNeuron.Runtime.WorkflowLedger

  def prepare(message, state) do
    steps = Map.get(state.runtime_context, :workflow_agent_steps, %{})

    if Map.has_key?(steps, state.node.node_id) do
      GenServer.call(
        state.coordinator,
        {:workflow_admit_message, state.node.node_id, message},
        5_000
      )
    else
      {:ok, message}
    end
  catch
    # A busy ledger may have admitted this same message before its reply was
    # lost. Redelivery reuses the message ID and its original attempt.
    :exit, {:timeout, {GenServer, :call, _}} -> {:defer, :workflow_admission_pending}
    :exit, reason -> {:error, {:workflow_admission_failed, reason}}
  end

  def admit(ledger, agent_id, message) do
    step_id =
      Message.headers(message)["mn.workflow.step_id"] ||
        WorkflowLedger.step_for_agent(ledger, agent_id)

    step = get_in(ledger, ["steps", step_id]) || %{}

    # Generated parent sinks can deliver their preliminary boundary before or
    # after the child finishes. Only the ledger owns the final child handoff.
    fence = WorkflowLedger.delivery_fence(step, agent_id, message)

    cond do
      step["status"] in ["completed", "partial", "skipped", "failed"] or fence == :stale ->
        {ledger, events} = WorkflowLedger.on_message_received(ledger, agent_id, message)
        {:skip, ledger, events}

      fence == :sealed ->
        {{:ok, message}, ledger, []}

      WorkflowLedger.enabled?(ledger) and ChildWorkflow.managed_target?(ledger, step) and
          not ledger_trigger?(message) ->
        {:skip, ledger, []}

      true ->
        admit_step(ledger, agent_id, message, step_id)
    end
  end

  defp admit_step(ledger, agent_id, message, step_id) do
    {ledger, events} = WorkflowLedger.on_message_received(ledger, agent_id, message)
    step = get_in(ledger, ["steps", step_id]) || %{}
    attempt = step["current_attempt"]

    result =
      cond do
        step["status"] in ["completed", "partial", "skipped", "failed"] ->
          :skip

        is_map(attempt) and
            (attempt["message_id"] == Message.id(message) or step["input_agent_id"] == agent_id) ->
          saved = step["last_message"] || StagedArtifact.resolve!(step["last_message_ref"])
          # Admission seals a delivery's metadata. Pause/resume can move the
          # ledger clocks without changing replayed report or output bodies.
          # Source inputs share the attempt but retain their own producer.
          headers =
            saved
            |> Message.headers()
            |> Map.filter(fn {key, _} -> String.starts_with?(key, "mn.workflow.") end)
            |> Map.drop(["mn.workflow.source_step_id", "mn.workflow.effect_origin"])

          {:ok, WorkflowLedger.decorate_message(ledger, agent_id, message, headers)}

        is_map(attempt) ->
          if redundant_trigger?(ledger, step, agent_id, message),
            do: :skip,
            else: {:error, :missing_workflow_attempt_context}

        true ->
          {:defer, :workflow_dependencies_pending}
      end

    {result, ledger, events}
  end

  defp redundant_trigger?(ledger, step, agent_id, message) do
    source = Message.headers(message)["mn.workflow.source_step_id"]

    upstream? =
      is_binary(source) and
        Enum.any?(ledger["edges"], &(&1["from"] == source and &1["to"] == step["id"]))

    generated? =
      ledger_trigger?(message) and Message.to(message) == agent_id and
        Message.headers(message)["mn.workflow.step_id"] == step["id"]

    # Parent outputs can race each other or a ledger-generated failure trigger.
    # Preserve the ledger's ignored decision without running another handler or
    # lending it the first delivery's attempt.
    List.first(step["agent_ids"] || []) == agent_id and
      get_in(ledger, ["messages", Message.id(message), "status"]) == "ignored" and
      (upstream? or generated?)
  end

  defp ledger_trigger?(message),
    do: Message.from(message) == "workflow_ledger" and Message.type(message) == "workflow_trigger"
end
