defmodule MirrorNeuron.Runtime.WorkflowAdmission do
  @moduledoc "Attaches the owning ledger attempt before a workflow handler executes."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Runtime.ChildWorkflow
  alias MirrorNeuron.Runtime.WorkflowLedger

  def prepare(message, state) do
    steps = Map.get(state.runtime_context, :workflow_agent_steps, %{})

    if Map.has_key?(steps, state.node.node_id) and
         is_nil(Message.headers(message)["mn.workflow.idempotency_key"]) do
      GenServer.call(
        state.coordinator,
        {:workflow_admit_message, state.node.node_id, message},
        5_000
      )
    else
      {:ok, message}
    end
  catch
    :exit, reason -> {:error, {:workflow_admission_failed, reason}}
  end

  def admit(ledger, agent_id, message) do
    step_id =
      Message.headers(message)["mn.workflow.step_id"] ||
        WorkflowLedger.step_for_agent(ledger, agent_id)

    step = get_in(ledger, ["steps", step_id]) || %{}

    # Generated parent sinks can deliver their preliminary boundary before or
    # after the child finishes. Only the ledger owns the final child handoff.
    ledger_trigger? =
      Message.from(message) == "workflow_ledger" and Message.type(message) == "workflow_trigger"

    if WorkflowLedger.enabled?(ledger) and ChildWorkflow.managed_target?(ledger, step) and
         not ledger_trigger? do
      {:skip, ledger, []}
    else
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
            |> Map.delete("mn.workflow.source_step_id")

          {:ok, WorkflowLedger.decorate_message(ledger, agent_id, message, headers)}

        is_map(attempt) ->
          if redundant_upstream_trigger?(ledger, step, agent_id, message),
            do: :skip,
            else: {:error, :missing_workflow_attempt_context}

        true ->
          {:defer, :workflow_dependencies_pending}
      end

    {result, ledger, events}
  end

  defp redundant_upstream_trigger?(ledger, step, agent_id, message) do
    source = Message.headers(message)["mn.workflow.source_step_id"]

    # A single-delivery step can receive one trigger from each completed parent.
    # The ledger already marks later triggers ignored; do not turn that decision
    # into a handler failure or lend them the first delivery's attempt.
    List.first(step["agent_ids"] || []) == agent_id and is_binary(source) and
      get_in(ledger, ["messages", Message.id(message), "status"]) == "ignored" and
      Enum.any?(ledger["edges"], &(&1["from"] == source and &1["to"] == step["id"]))
  end
end
