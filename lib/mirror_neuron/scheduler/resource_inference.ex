defmodule MirrorNeuron.Scheduler.ResourceInference do
  @moduledoc false

  def infer(_manifest, node, resource_request, constraints, requires_services) do
    %{
      "resource_request" => resource_request,
      "constraints" => uniq_maps(constraints),
      "requires_services" => uniq_maps(requires_services),
      "placement_requirements" => placement_requirements(node)
    }
  end

  defp placement_requirements(node) do
    explicit =
      map_get(node, "placement_requirements") ||
        node
        |> map_get("config")
        |> map_get("placement_requirements")

    case explicit do
      %{} = requirements ->
        %{
          "models" => requirements |> map_get("models") |> normalize_list()
        }

      _ ->
        %{"models" => []}
    end
  end

  defp normalize_list(values) when is_list(values), do: Enum.filter(values, &is_map/1)
  defp normalize_list(_values), do: []

  defp uniq_maps(values) do
    values
    |> List.wrap()
    |> Enum.reduce([], fn value, acc ->
      key = :erlang.term_to_binary(value)

      if Enum.any?(acc, fn {existing_key, _value} -> existing_key == key end) do
        acc
      else
        [{key, value} | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      existing_atom_value(map, key)
    end
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp existing_atom_value(map, key) do
    atom = String.to_existing_atom(key)
    if Map.has_key?(map, atom), do: Map.get(map, atom)
  rescue
    ArgumentError -> nil
  end
end
