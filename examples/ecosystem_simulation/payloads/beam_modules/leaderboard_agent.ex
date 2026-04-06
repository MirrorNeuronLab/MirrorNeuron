defmodule MirrorNeuron.Examples.EcosystemSimulation.LeaderboardAgent do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Examples.EcosystemSimulation.Core

  @impl true
  def init(node), do: {:ok, %{config: node.config, last_summary: nil}}

  @impl true
  def handle_message(message, state, _context) do
    payload = payload(message) || %{}
    region_messages = Map.get(payload, "messages", []) |> Enum.map(&atomize/1)
    summary = Core.summarize_regions(region_messages)

    {:ok, %{state | last_summary: summary}, [{:complete_job, stringify(summary)}]}
  end

  @impl true
  def inspect_state(state) do
    %{
      last_summary:
        case state.last_summary do
          nil -> nil
          summary -> %{"region_count" => summary.region_count, "population_alive" => summary.population_alive}
        end
    }
  end

  defp atomize(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      atom_key =
        case key do
          value when is_atom(value) -> value
          value when is_binary(value) -> String.to_atom(value)
        end

      {atom_key, atomize(value)}
    end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp stringify(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      out_key = if is_atom(key), do: Atom.to_string(key), else: key
      {out_key, stringify(value)}
    end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
