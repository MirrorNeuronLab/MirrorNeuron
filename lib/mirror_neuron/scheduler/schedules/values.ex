defmodule MirrorNeuron.Scheduler.Schedules.Values do
  @moduledoc "Normalizes schedule maps at the trigger boundary."

  def stringify(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify(value)}
    end)
  end

  def stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  def stringify(value), do: value
end
