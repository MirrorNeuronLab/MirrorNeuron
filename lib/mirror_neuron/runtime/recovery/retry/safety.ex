defmodule MirrorNeuron.Runtime.RunRetry.Safety do
  @moduledoc "Verifies completed work, replay boundaries, artifacts and uncertainty about external effects."

  alias MirrorNeuron.Runtime.RecoverySafety
  alias MirrorNeuron.Runtime.RetryArtifacts
  alias MirrorNeuron.Artifacts.StagedArtifact
  alias MirrorNeuron.Runtime.WorkflowRetry

  def completed_work_matches(job, ledger) do
    current = job["workflow_state"] || %{}
    current_steps = current["steps"] || %{}

    if Enum.all?(current_steps, fn {id, step} ->
         step["status"] not in ~w(completed partial) or
           get_in(ledger, ["steps", id, "status"]) == step["status"]
       end),
       do: :ok,
       else: {:error, "The checkpoint is missing completed work. Start a new run."}
  end

  def safe_work(job, ledger, manifest, artifacts) do
    steps = Enum.map(WorkflowRetry.unfinished(ledger), &ledger["steps"][&1])

    missing_nodes =
      Enum.filter(steps, fn step ->
        (step["attempt_count"] || 0) > 0 and
          not Map.has_key?(ledger["child_workflows"] || %{}, step["id"]) and
          not Enum.any?(manifest.nodes, &(&1.node_id in (step["agent_ids"] || [step["run"]])))
      end)

    if missing_nodes != [], do: raise(ArgumentError, "Checkpoint execution identity is missing")

    unsafe =
      Enum.flat_map(steps, fn step ->
        if Map.get(step, "attempt_count", 0) > 0 and
             not Map.has_key?(ledger["child_workflows"] || %{}, step["id"]) do
          manifest.nodes
          |> Enum.filter(&(&1.node_id in (step["agent_ids"] || [step["run"]])))
          |> Enum.filter(&(&1.agent_type in ["module", "executor"]))
          |> Enum.reject(&RecoverySafety.config_retry_safe?(&1.config))
          |> Enum.map(&{step["id"] <> ":" <> &1.node_id, &1})
        else
          []
        end
      end)

    handoff_steps =
      for {id, node} <- unsafe,
          get_in(node.config, ["artifact_handoff", "version"]) == "mn.artifact_handoff/v1",
          do: id

    with {:ok, safe} <- RetryArtifacts.verify(job, ledger, manifest, handoff_steps, artifacts) do
      blocked = for {id, _node} <- unsafe, id not in safe, do: id

      if blocked == [],
        do: :ok,
        else: {:error, "Uncertain external effects block replay: #{Enum.join(blocked, ", ")}."}
    end
  end

  def verify_boundaries(ledger) do
    preserved = WorkflowRetry.preserved(ledger)

    missing =
      Enum.filter(WorkflowRetry.unfinished(ledger), fn id ->
        step = ledger["steps"][id]

        parents =
          for edge <- ledger["edges"] || [], edge["to"] == id, do: edge["from"]

        (Map.get(step, "attempt_count", 0) > 0 or Enum.all?(parents, &(&1 in preserved))) and
          is_nil(step["last_message"]) and is_nil(step["instance_input"]) and
          not StagedArtifact.ref?(step["last_message_ref"]) and
          not Map.has_key?(ledger["child_workflows"] || %{}, id)
      end)

    if missing == [],
      do: :ok,
      else:
        {:error,
         "Unfinished step inputs are missing: #{Enum.join(missing, ", ")}. Start a new run."}
  end

  def verify_references(value) when is_map(value) do
    if Enum.any?(Map.keys(value), &String.ends_with?(to_string(&1), "_ref_error")) do
      {:error, "A checkpoint output could not be retained. Start a new run."}
    else
      if StagedArtifact.ref?(value) do
        value |> StagedArtifact.resolve!(timeout_ms: 0) |> verify_references()
      else
        Enum.reduce_while(Map.values(value), :ok, fn item, :ok ->
          case verify_references(item) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end
    end
  rescue
    _ -> {:error, "A checkpoint artifact is missing or has changed."}
  end

  def verify_references(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case verify_references(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def verify_references(_), do: :ok
end
