defmodule MirrorNeuron.Runtime.WorkflowLedger.Dependencies do
  @moduledoc "Evaluates edge acceptance and workflow trigger rules."

  alias MirrorNeuron.Runtime.DynamicWorkflow
  alias MirrorNeuron.Runtime.WorkflowLedger.State

  @successful_step_statuses ["completed", "partial", "skipped"]

  def dependencies_satisfied?(state, step) do
    edges = incoming_edges(state, step)

    case Map.get(step, "trigger_rule", %{"rule" => "all_success"}) do
      %{"rule" => "all_success"} ->
        Enum.all?(edges, &dependency_satisfied?(state, &1))

      %{"rule" => "all_done"} ->
        Enum.all?(edges, &dependency_terminal?(state, &1))

      %{"rule" => "one_success"} ->
        Enum.any?(edges, &dependency_success?(state, &1))

      %{"rule" => "one_done"} ->
        Enum.any?(edges, &dependency_terminal?(state, &1))

      %{"rule" => "one_failed"} ->
        Enum.any?(edges, &dependency_failed?(state, &1))

      %{"rule" => "none_failed_min_one_success"} ->
        Enum.all?(edges, &dependency_terminal?(state, &1)) and
          not Enum.any?(edges, &dependency_failed?(state, &1)) and
          Enum.any?(edges, &dependency_success?(state, &1))

      %{"rule" => "quorum_success", "quorum" => quorum} ->
        Enum.count(edges, &dependency_success?(state, &1)) >= quorum

      _ ->
        Enum.all?(edges, &dependency_satisfied?(state, &1))
    end
  end

  def dependencies_impossible?(state, step) do
    edges = incoming_edges(state, step)

    if edges == [] do
      false
    else
      all_terminal? = Enum.all?(edges, &dependency_terminal?(state, &1))

      case Map.get(step, "trigger_rule", %{"rule" => "all_success"}) do
        %{"rule" => "all_success"} ->
          all_terminal? and not dependencies_satisfied?(state, step)

        %{"rule" => "one_success"} ->
          all_terminal? and not dependencies_satisfied?(state, step)

        %{"rule" => "one_failed"} ->
          all_terminal? and not dependencies_satisfied?(state, step)

        %{"rule" => "none_failed_min_one_success"} ->
          all_terminal? and not dependencies_satisfied?(state, step)

        %{"rule" => "quorum_success", "quorum" => quorum} ->
          successes = Enum.count(edges, &dependency_success?(state, &1))
          pending = Enum.count(edges, &(not dependency_terminal?(state, &1)))
          successes + pending < quorum

        _ ->
          false
      end
    end
  end

  def blocked_dependencies(state, step) do
    state
    |> incoming_edges(step)
    |> Enum.reject(&dependency_relevant?(state, step, &1))
    |> Enum.map(&blocked_dependency_summary(state, &1))
  end

  defp dependency_relevant?(state, step, edge) do
    case Map.get(step, "trigger_rule", %{"rule" => "all_success"}) do
      %{"rule" => "all_done"} -> dependency_terminal?(state, edge)
      %{"rule" => "one_success"} -> dependency_success?(state, edge)
      %{"rule" => "one_done"} -> dependency_terminal?(state, edge)
      %{"rule" => "one_failed"} -> dependency_failed?(state, edge)
      _ -> dependency_satisfied?(state, edge)
    end
  end

  defp dependency_satisfied?(state, edge) do
    if DynamicWorkflow.dependency_checkpointed?(state, edge) do
      true
    else
      case State.get_step(state, Map.get(edge, "from")) do
        nil -> true
        parent -> parent_status_accepted?(Map.get(parent, "status"), Map.get(edge, "accepts"))
      end
    end
  end

  def dependency_success?(state, edge) do
    if DynamicWorkflow.dependency_checkpointed?(state, edge) do
      true
    else
      case State.get_step(state, Map.get(edge, "from")) do
        nil ->
          true

        parent ->
          Map.get(parent, "terminal_outcome") == "success" or
            Map.get(parent, "status") == "completed"
      end
    end
  end

  def dependency_failed?(state, edge) do
    case State.get_step(state, Map.get(edge, "from")) do
      nil ->
        false

      parent ->
        Map.get(parent, "terminal_outcome") == "failed" or Map.get(parent, "status") == "failed"
    end
  end

  def dependency_terminal?(state, edge) do
    if DynamicWorkflow.dependency_checkpointed?(state, edge) do
      true
    else
      case State.get_step(state, Map.get(edge, "from")) do
        nil -> true
        parent -> State.step_terminal?(parent)
      end
    end
  end

  defp blocked_dependency_summary(state, edge) do
    parent = State.get_step(state, Map.get(edge, "from")) || %{}

    %{
      "from" => Map.get(edge, "from"),
      "status" => Map.get(parent, "status", "unknown"),
      "accepts" => normalized_accepts(Map.get(edge, "accepts")),
      "outcome" => Map.get(parent, "terminal_outcome")
    }
  end

  def incoming_edges(%{"edges" => edges}, %{"id" => step_id}) when is_list(edges) do
    Enum.filter(edges, &(Map.get(&1, "to") == step_id))
  end

  def incoming_edges(_state, _step), do: []

  defp parent_status_accepted?(status, accepts) do
    status in @successful_step_statuses and
      workflow_status_alias(status) in normalized_accepts(accepts)
  end

  defp workflow_status_alias("completed"), do: "done"

  defp workflow_status_alias(status), do: status

  defp normalized_accepts(accepts) when is_list(accepts) do
    accepts
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ["done"]
      values -> values
    end
  end

  defp normalized_accepts(_accepts), do: ["done"]
end
