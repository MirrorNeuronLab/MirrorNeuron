defmodule MirrorNeuron.Manifest.WorkflowGraph do
  @moduledoc "Validates workflow dependency graphs, trigger rules and dynamic expansion."

  alias MirrorNeuron.Runtime.DynamicWorkflowSpec
  alias MirrorNeuron.Manifest.Values
  alias MirrorNeuron.Runtime.WorkflowTrigger

  def validate_workflow_flow(errors, manifest) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    steps = Map.get(flow, "steps", [])
    graph = if is_map(Map.get(flow, "graph")), do: Map.get(flow, "graph"), else: %{}
    graph_edges = Map.get(graph, "edges", [])

    errors =
      Values.add_errors(
        errors,
        MirrorNeuron.Runtime.WorkflowActivity.validation_errors(flow, manifest.nodes)
      )

    if is_list(steps) and steps != [] do
      step_ids =
        steps
        |> Enum.filter(&is_map/1)
        |> Enum.map(&(Map.get(&1, "id") |> to_string()))

      duplicate_ids = step_ids -- Enum.uniq(step_ids)
      valid_ids = MapSet.new(Enum.reject(step_ids, &(&1 == "")))

      step_errors =
        steps
        |> Enum.filter(&is_map/1)
        |> Enum.flat_map(fn step ->
          step_id = Map.get(step, "id") |> to_string()

          case WorkflowTrigger.from_step(step, graph) do
            {:ok, %{"rule" => "quorum_success", "quorum" => quorum}} ->
              incoming_count =
                graph_edges
                |> List.wrap()
                |> Enum.count(&(is_map(&1) and Map.get(&1, "to") == step_id))

              []
              |> Values.maybe_collect_error(step_id == "", "workflow step id is required")
              |> Values.maybe_collect_error(
                incoming_count > 0 and quorum > incoming_count,
                "workflow step #{step_id} quorum #{quorum} exceeds its #{incoming_count} upstream steps"
              )

            {:ok, _trigger} ->
              Values.maybe_collect_error([], step_id == "", "workflow step id is required")

            {:error, reason} ->
              ["workflow step #{step_id || "unknown"} has invalid trigger rule: #{reason}"]
          end
        end)

      graph_errors =
        graph_edges
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.flat_map(fn edge ->
          from = to_string(Map.get(edge, "from") || "")
          to = to_string(Map.get(edge, "to") || "")

          []
          |> Values.maybe_collect_error(
            not MapSet.member?(valid_ids, from),
            "workflow edge references missing from step #{from}"
          )
          |> Values.maybe_collect_error(
            not MapSet.member?(valid_ids, to),
            "workflow edge references missing to step #{to}"
          )
          |> Values.maybe_collect_error(
            from == to and from != "",
            "workflow edge cannot point from #{from} to itself"
          )
        end)

      cycle_errors =
        if graph_errors == [] and
             workflow_cycle?(MapSet.to_list(valid_ids), List.wrap(graph_edges)) do
          ["workflow graph must be acyclic"]
        else
          []
        end

      dynamic_errors =
        DynamicWorkflowSpec.validation_errors(
          flow,
          Enum.map(manifest.nodes, & &1.node_id)
        )

      errors
      |> Values.add_errors(
        Enum.map(Enum.uniq(duplicate_ids), &"duplicate workflow step id #{&1}")
      )
      |> Values.add_errors(step_errors)
      |> Values.add_errors(graph_errors)
      |> Values.add_errors(cycle_errors)
      |> Values.add_errors(dynamic_errors)
    else
      errors
    end
  end

  defp workflow_cycle?(step_ids, edges) do
    parents = Map.new(step_ids, &{&1, MapSet.new()})

    parents =
      Enum.reduce(edges, parents, fn edge, acc ->
        from = to_string(Map.get(edge, "from") || "")
        to = to_string(Map.get(edge, "to") || "")

        if Map.has_key?(acc, from) and Map.has_key?(acc, to) do
          Map.update!(acc, to, &MapSet.put(&1, from))
        else
          acc
        end
      end)

    do_workflow_cycle?(parents, [])
  end

  defp do_workflow_cycle?(parents, removed) do
    ready =
      parents
      |> Enum.reject(fn {step_id, _parents} -> step_id in removed end)
      |> Enum.filter(fn {_step_id, dependencies} ->
        MapSet.subset?(dependencies, MapSet.new(removed))
      end)
      |> Enum.map(&elem(&1, 0))

    case ready do
      [] ->
        map_size(parents) != length(removed)

      _ ->
        do_workflow_cycle?(parents, Enum.uniq(removed ++ ready))
    end
  end
end
