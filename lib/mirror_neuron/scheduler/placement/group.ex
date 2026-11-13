defmodule MirrorNeuron.Scheduler.Placement.Group do
  @moduledoc "Fits a group of workers against a single node without losing reservations."

  alias MirrorNeuron.Scheduler.Placement.Allocation
  alias MirrorNeuron.Scheduler.Placement.Usage

  def group_node_plan(node, demands, used, eligible?) do
    if Enum.all?(demands, eligible?) do
      fit_demand_group(node, demands, used)
    else
      :error
    end
  end

  defp fit_demand_group(node, demands, used) do
    demands
    |> Enum.reduce_while(
      {:ok, Usage.empty_resources(), %{}, Usage.normalize_usage(used)},
      fn demand, group_acc ->
        fit_demand_in_group(node, demand, group_acc)
      end
    )
    |> group_plan_result()
  end

  defp fit_demand_in_group(node, demand, {:ok, resources_acc, allocations, used_acc}) do
    case Allocation.fit_allocation(node, used_acc, demand) do
      {:ok, allocation} ->
        {:cont,
         {:ok, Usage.add_resources(resources_acc, demand["resources"]),
          Map.put(allocations, demand["agent_id"], allocation),
          Usage.add_usage(used_acc, demand["resources"], allocation)}}

      {:error, _reason} ->
        {:halt, :error}
    end
  end

  defp group_plan_result({:ok, group_resources, allocations, next_usage}) do
    {:ok, %{"resources" => group_resources, "allocations" => allocations, "usage" => next_usage}}
  end

  defp group_plan_result(:error), do: :error
end
