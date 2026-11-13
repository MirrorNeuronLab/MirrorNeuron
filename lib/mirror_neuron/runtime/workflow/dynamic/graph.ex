defmodule MirrorNeuron.Runtime.DynamicWorkflow.Graph do
  @moduledoc "Checks region reachability and acyclicity before committing a candidate graph."

  alias MirrorNeuron.Runtime.DynamicWorkflow.State

  def validate_candidate(state, region) do
    ids = Map.keys(state["steps"])
    edges = state["edges"]

    cond do
      Enum.any?(
        edges,
        &(not Map.has_key?(state["steps"], &1["from"]) or
              not Map.has_key?(state["steps"], &1["to"]))
      ) ->
        {:error, "patch leaves a dangling workflow edge"}

      cyclic?(ids, edges) ->
        {:error, "patch would make the active workflow graph cyclic"}

      region["strategy"] == "replace_path" ->
        validate_replace_path(state, region)

      region["strategy"] == "checkpoint_fanout" ->
        validate_checkpoint_fanout(state, region)

      true ->
        {:error, "unsupported dynamic region strategy #{inspect(region["strategy"])}"}
    end
  end

  defp validate_replace_path(state, region) do
    controller = region["controller"]
    exit_id = region["exit"]
    dynamic_ids = region_dynamic_ids(state, region["id"])

    cond do
      not reachable?(state, controller, exit_id) ->
        {:error, "replace_path patch must keep the fixed exit reachable from its controller"}

      Enum.any?(dynamic_ids, fn id ->
        not reachable?(state, controller, id) or not reachable?(state, id, exit_id)
      end) ->
        {:error, "every replace_path instance must remain on a controller-to-exit path"}

      true ->
        :ok
    end
  end

  defp validate_checkpoint_fanout(state, region) do
    if Enum.all?(
         region_dynamic_ids(state, region["id"]),
         &reachable?(state, region["controller"], &1)
       ),
       do: :ok,
       else: {:error, "every checkpoint_fanout instance must be controller-reachable"}
  end

  defp region_dynamic_ids(state, region_id) do
    state["steps"]
    |> Enum.filter(fn {_id, step} ->
      State.dynamic_step?(step) and step["region_id"] == region_id
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp reachable?(state, source, target),
    do: reachable?(state["edges"], MapSet.new(), [source], target)

  defp reachable?(_edges, _seen, [], _target), do: false

  defp reachable?(_edges, _seen, [target | _], target), do: true

  defp reachable?(edges, seen, [current | rest], target) do
    if MapSet.member?(seen, current) do
      reachable?(edges, seen, rest, target)
    else
      next = for edge <- edges, edge["from"] == current, do: edge["to"]
      reachable?(edges, MapSet.put(seen, current), rest ++ next, target)
    end
  end

  defp cyclic?(ids, edges) do
    parents = Map.new(ids, &{&1, MapSet.new()})

    parents =
      Enum.reduce(edges, parents, fn edge, acc ->
        if Map.has_key?(acc, edge["from"]) and Map.has_key?(acc, edge["to"]) do
          Map.update!(acc, edge["to"], &MapSet.put(&1, edge["from"]))
        else
          acc
        end
      end)

    remove_acyclic(parents, MapSet.new()) != map_size(parents)
  end

  defp remove_acyclic(parents, removed) do
    ready =
      Enum.filter(parents, fn {id, dependencies} ->
        not MapSet.member?(removed, id) and MapSet.subset?(dependencies, removed)
      end)

    if ready == [] do
      MapSet.size(removed)
    else
      next = Enum.reduce(ready, removed, fn {id, _}, acc -> MapSet.put(acc, id) end)
      remove_acyclic(parents, next)
    end
  end
end
