defmodule MirrorNeuron.Scheduler do
  @moduledoc "Public placement planning and plan inspection API."

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Scheduler.Placement.Planner
  alias MirrorNeuron.Scheduler.Placement.Policy

  defdelegate supported_job_types(), to: Policy
  defdelegate supported_strategies(), to: Policy

  def availability(%Manifest{} = manifest, opts \\ []) do
    case plan(manifest, opts) do
      {:ok, plan} ->
        {:ok, %{"status" => "runnable_now", "plan" => plan}}

      {:error, reason} ->
        free_opts = Keyword.put(opts, :jobs, [])

        case plan(manifest, free_opts) do
          {:ok, free_plan} ->
            {:blocked,
             %{
               "status" => "runnable_later",
               "reason" => reason,
               "plan_when_free" => free_plan
             }}

          {:error, free_reason} ->
            {:error, %{"status" => "not_runnable", "reason" => free_reason}}
        end
    end
  end

  def plan(%Manifest{} = manifest, opts \\ []) do
    if Keyword.get(opts, :scheduler, true) do
      Planner.plan(manifest, opts)
    else
      {:ok, Planner.disabled_plan(manifest)}
    end
  end

  def target_node(%{"placements" => placements}, agent_id) when is_list(placements) do
    placements
    |> Enum.find(&(Map.get(&1, "agent_id") == agent_id))
    |> case do
      %{"node" => node} -> node
      _ -> nil
    end
  end

  def target_node(_plan, _agent_id), do: nil

  def allocation(%{"placements" => placements}, agent_id) when is_list(placements) do
    placements
    |> Enum.find(&(Map.get(&1, "agent_id") == agent_id))
    |> case do
      %{"allocations" => allocations} when is_map(allocations) -> allocations
      _ -> %{}
    end
  end

  def allocation(_plan, _agent_id), do: %{}

  def affected_agent_ids(%{"placements" => placements}, node) when is_list(placements) do
    node = to_string(node)

    placements
    |> Enum.filter(&(Map.get(&1, "node") == node))
    |> Enum.map(&Map.get(&1, "agent_id"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def affected_agent_ids(_plan, _node), do: []

  def merge_plan(%{"placements" => existing_placements} = existing, %{
        "placements" => replacement_placements
      })
      when is_list(existing_placements) and is_list(replacement_placements) do
    replacement_ids =
      replacement_placements
      |> Enum.map(&Map.get(&1, "agent_id"))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    placements =
      existing_placements
      |> Enum.reject(&(Map.get(&1, "agent_id") in replacement_ids))
      |> Kernel.++(replacement_placements)

    existing
    |> Map.put("placements", placements)
    |> Map.put("placement_count", length(placements))
    |> Map.put("generated_at", MirrorNeuron.Runtime.timestamp())
  end

  def merge_plan(_existing, partial), do: partial

  def job_type(%Manifest{} = manifest), do: Policy.normalize_job_type(manifest)

  def strategy(%Manifest{} = manifest), do: Policy.normalize_strategy(manifest)
end
