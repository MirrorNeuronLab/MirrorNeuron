defmodule MirrorNeuron.Manifest.Shape do
  @moduledoc "Checks input containers and identifiers before normalization traverses a manifest."

  def validate(raw) when is_map(raw) do
    case flow_errors(Map.get(raw, "flow")) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_raw), do: {:error, ["manifest must be an object"]}

  defp flow_errors(nil), do: []

  defp flow_errors(flow) when is_map(flow) do
    collection(flow, "nodes", "flow", ~w(node_id agent_type type role)) ++
      collection(flow, "edges", "flow", ~w(edge_id from_node to_node message_type routing_mode)) ++
      collection(flow, "steps", "flow", ~w(id)) ++ graph_errors(Map.get(flow, "graph"))
  end

  defp flow_errors(_flow), do: ["flow must be an object"]

  defp graph_errors(nil), do: []

  defp graph_errors(graph) when is_map(graph),
    do: collection(graph, "edges", "flow.graph", ~w(id from to))

  defp graph_errors(_graph), do: ["flow.graph must be an object"]

  defp collection(parent, key, path, identifiers) do
    path = path <> "." <> key

    case Map.get(parent, key) do
      nil ->
        []

      values when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.flat_map(fn {value, index} -> object(value, "#{path}[#{index}]", identifiers) end)

      _ ->
        ["#{path} must be a list"]
    end
  end

  defp object(value, path, identifiers) when is_map(value) do
    Enum.flat_map(identifiers, fn key ->
      case Map.get(value, key) do
        nil -> []
        text when is_binary(text) -> []
        _ -> ["#{path}.#{key} must be a string"]
      end
    end)
  end

  defp object(_value, path, _identifiers), do: ["#{path} must be an object"]
end
