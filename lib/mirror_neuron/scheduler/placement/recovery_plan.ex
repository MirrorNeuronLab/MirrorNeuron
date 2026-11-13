defmodule MirrorNeuron.Scheduler.RecoveryPlan do
  @moduledoc "Recovery placement planning and final target eligibility checks."

  alias MirrorNeuron.Scheduler

  @active_node_statuses ["healthy", "joining"]

  def recovery_scheduler_plan(manifest, opts) do
    case Scheduler.plan(manifest, opts) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:placement_blocked, format_reason(reason)}
    end
  end

  def validate_recovery_plan(%{"placements" => placements}, failed_node, opts)
      when is_list(placements) do
    nodes_by_name =
      opts
      |> validation_nodes()
      |> Enum.into(%{}, fn node -> {validation_node_name(node), node} end)
      |> Map.reject(fn {name, _node} -> is_nil(name) end)

    if map_size(nodes_by_name) == 0 do
      :ok
    else
      placements
      |> Enum.reduce_while(:ok, fn placement, :ok ->
        target = Map.get(placement, "node")
        node = Map.get(nodes_by_name, target)
        status = validation_node_status(node)

        cond do
          is_nil(target) ->
            {:halt, {:placement_blocked, "scheduler placement is missing a target node"}}

          target in List.wrap(failed_node) ->
            {:halt,
             {:placement_blocked, "final validation rejected placement on failed node #{target}"}}

          is_nil(node) ->
            {:halt,
             {:placement_blocked, "target node #{target} is not visible during final validation"}}

          status not in @active_node_statuses ->
            {:halt,
             {:placement_blocked,
              "target node #{target} is #{status || "unknown"} during final validation"}}

          validation_node_scheduling_eligible?(node) == false ->
            {:halt,
             {:placement_blocked,
              "target node #{target} is scheduling-ineligible during final validation"}}

          true ->
            {:cont, :ok}
        end
      end)
    end
  end

  def validate_recovery_plan(_plan, _failed_node, _opts),
    do: {:placement_blocked, "scheduler plan is missing placements"}

  defp validation_nodes(opts) do
    scheduler_opts = Keyword.get(opts, :scheduler_opts, [])

    nodes =
      Keyword.get(opts, :validation_nodes) ||
        Keyword.get(scheduler_opts, :nodes) ||
        default_validation_nodes()

    nodes
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp default_validation_nodes do
    case MirrorNeuron.inspect_nodes() do
      nodes when is_list(nodes) -> nodes
      _ -> []
    end
  rescue
    _ -> []
  catch
    _kind, _reason -> []
  end

  defp validation_node_name(node) do
    Map.get(node, "name") || Map.get(node, :name) || Map.get(node, "node") || Map.get(node, :node)
  end

  defp validation_node_status(nil), do: nil

  defp validation_node_status(node),
    do: Map.get(node, "status") || Map.get(node, :status) || "healthy"

  defp validation_node_scheduling_eligible?(node) do
    cond do
      is_nil(node) -> false
      Map.has_key?(node, "scheduling_eligible") -> Map.get(node, "scheduling_eligible")
      Map.has_key?(node, :scheduling_eligible) -> Map.get(node, :scheduling_eligible)
      true -> true
    end
  end

  def preferred_start_node(%{"placements" => placements}, failed_node)
      when is_list(placements) do
    failed_nodes =
      failed_node
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    placements
    |> Enum.map(&Map.get(&1, "node"))
    |> Enum.reject(&(is_nil(&1) or &1 in failed_nodes))
    |> List.first()
  end

  def preferred_start_node(_scheduler_plan, _failed_node), do: nil

  def current_target_nodes(job, agent_ids) do
    agent_ids
    |> Enum.map(&Scheduler.target_node(Map.get(job, "scheduler", %{}), &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def scheduler_opts(opts, overrides),
    do: Keyword.merge(Keyword.get(opts, :scheduler_opts, []), overrides)

  defp format_reason(reason) when is_binary(reason), do: reason
end
