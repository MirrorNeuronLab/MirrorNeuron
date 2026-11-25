defmodule MirrorNeuron.Runtime.DynamicWorkflow.Graph do
  @moduledoc "Checks region reachability and acyclicity before committing a candidate graph."

  alias MirrorNeuron.Runtime.DynamicWorkflow.State
  alias MirrorNeuron.Runtime.WorkflowDigraph

  def validate_candidate(state, region) do
    edges = Enum.map(state["edges"], &{&1["from"], &1["to"]})

    case WorkflowDigraph.validate(
           Map.keys(state["steps"]),
           edges,
           &validate_region(&1, state, region)
         ) do
      {:error, :dangling_edge} -> {:error, "patch leaves a dangling workflow edge"}
      {:error, :cycle} -> {:error, "patch would make the active workflow graph cyclic"}
      result -> result
    end
  end

  defp validate_region(graph, state, %{"strategy" => "replace_path"} = region) do
    exit_id = region["exit"]
    from_controller = MapSet.new(:digraph_utils.reachable([region["controller"]], graph))
    to_exit = MapSet.new(:digraph_utils.reaching([exit_id], graph))
    dynamic_ids = region_dynamic_ids(state, region["id"])

    cond do
      not MapSet.member?(from_controller, exit_id) ->
        {:error, "replace_path patch must keep the fixed exit reachable from its controller"}

      not MapSet.subset?(dynamic_ids, from_controller) or not MapSet.subset?(dynamic_ids, to_exit) ->
        {:error, "every replace_path instance must remain on a controller-to-exit path"}

      true ->
        :ok
    end
  end

  defp validate_region(graph, state, %{"strategy" => "checkpoint_fanout"} = region) do
    reachable = MapSet.new(:digraph_utils.reachable([region["controller"]], graph))

    if MapSet.subset?(region_dynamic_ids(state, region["id"]), reachable),
      do: :ok,
      else: {:error, "every checkpoint_fanout instance must be controller-reachable"}
  end

  defp validate_region(_graph, _state, region),
    do: {:error, "unsupported dynamic region strategy #{inspect(region["strategy"])}"}

  defp region_dynamic_ids(state, region_id) do
    for {id, step} <- state["steps"],
        State.dynamic_step?(step) and step["region_id"] == region_id,
        into: MapSet.new() do
      id
    end
  end
end
