defmodule MirrorNeuron.Runtime.WorkflowAdmission do
  @moduledoc "Attaches the owning ledger attempt before a workflow handler executes."

  alias MirrorNeuron.Message
  alias MirrorNeuron.Artifacts.StagedArtifact
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
    {ledger, events} = WorkflowLedger.on_message_received(ledger, agent_id, message)

    step_id =
      Message.headers(message)["mn.workflow.step_id"] ||
        WorkflowLedger.step_for_agent(ledger, agent_id)

    step = get_in(ledger, ["steps", step_id]) || %{}
    attempt = step["current_attempt"]

    result =
      cond do
        step["status"] in ["completed", "partial", "skipped", "failed"] ->
          :skip

        is_map(attempt) and attempt["message_id"] == Message.id(message) ->
          saved = step["last_message"] || StagedArtifact.resolve!(step["last_message_ref"])
          # Admission seals a delivery's metadata. Pause/resume can move the
          # ledger clocks without changing replayed report or output bodies.
          headers =
            saved
            |> Message.headers()
            |> Map.filter(fn {key, _} -> String.starts_with?(key, "mn.workflow.") end)

          {:ok, WorkflowLedger.decorate_message(ledger, agent_id, message, headers)}

        is_map(attempt) ->
          {:error, :missing_workflow_attempt_context}

        true ->
          {:defer, :workflow_dependencies_pending}
      end

    {result, ledger, events}
  end
end
