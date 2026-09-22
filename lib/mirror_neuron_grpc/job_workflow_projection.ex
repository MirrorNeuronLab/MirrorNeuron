defmodule MirrorNeuron.Grpc.JobWorkflowProjection do
  @moduledoc false

  @workflow_fields ~w(workflow_id mode schema source sink entrypoint)
  @step_fields ~w(id label goal action run kind agent_id agent_ids)
  @edge_fields ~w(id from to event required accepts condition)
  @binding_fields ~w(id role working_on model uses alias display_name label name)
  @worker_fields ~w(id node_id role working_on model uses alias display_name label name)

  def from_definition(%{"manifest" => manifest}) when is_map(manifest) do
    workflow = manifest["workflow"]
    runtime = manifest["runtime"]

    if is_map(workflow) do
      bindings = if is_map(runtime), do: runtime["bindings"], else: nil

      %{
        "workflow" =>
          Map.take(workflow, @workflow_fields)
          |> Map.put("steps", project_list(workflow["steps"], @step_fields))
          |> Map.put("edges", project_list(workflow["edges"], @edge_fields)),
        "runtime" => %{"bindings" => project_bindings(bindings)}
      }
    else
      %{"workflow" => %{"steps" => [], "edges" => []}, "runtime" => %{"bindings" => %{}}}
    end
  end

  def from_definition(_definition),
    do: %{"workflow" => %{"steps" => [], "edges" => []}, "runtime" => %{"bindings" => %{}}}

  defp project_list(value, keys) when is_list(value) do
    for item <- value, is_map(item), do: Map.take(item, keys)
  end

  defp project_list(_value, _keys), do: []

  defp project_bindings(bindings) when is_map(bindings) do
    Map.new(bindings, fn {key, binding} ->
      {key, project_binding(binding)}
    end)
  end

  defp project_bindings(_bindings), do: %{}

  defp project_binding(binding) when is_map(binding) do
    result = Map.take(binding, @binding_fields)

    result =
      if is_map(binding["worker"]),
        do: Map.put(result, "worker", Map.take(binding["worker"], @worker_fields)),
        else: result

    if is_list(binding["workers"]),
      do: Map.put(result, "workers", project_list(binding["workers"], @worker_fields)),
      else: result
  end

  defp project_binding(_binding), do: %{}
end
