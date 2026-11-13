defmodule MirrorNeuron.Manifest.Completion do
  @moduledoc "Enforces owning-step and terminal-sink completion contracts."

  alias MirrorNeuron.Manifest.Values

  def validate_completion_contract(errors, manifest) do
    step_runs = workflow_step_run_ids(manifest)
    outgoing = outgoing_edge_counts(manifest)

    completion_errors =
      Enum.flat_map(manifest.nodes, fn node ->
        config = if is_map(node.config), do: node.config, else: %{}
        terminal_sink? = Map.get(config, "terminal_sink") == true
        complete_run? = Map.get(config, "complete_run") == true
        complete_on_message? = Map.get(config, "complete_on_message") == true
        complete_after? = completion_threshold?(Map.get(config, "complete_after"))
        output_message_type = Map.get(config, "output_message_type")

        []
        |> Values.maybe_collect_error(
          contains_completion_key?(config, "complete_job"),
          "node #{node.node_id} config uses unsupported complete_job; use complete_run or complete_step"
        )
        |> Values.maybe_collect_error(
          contains_completion_key?(config, "complete_job?"),
          "node #{node.node_id} config uses unsupported complete_job?; use complete_run or complete_step"
        )
        |> Values.maybe_collect_error(
          complete_on_message? and not valid_output_message_type?(output_message_type) and
            not (terminal_sink? and complete_run?),
          "node #{node.node_id} complete_on_message requires output_message_type or terminal_sink with complete_run"
        )
        |> Values.maybe_collect_error(
          complete_after? and not valid_output_message_type?(output_message_type) and
            not (terminal_sink? and complete_run?),
          "node #{node.node_id} complete_after requires output_message_type or terminal_sink with complete_run"
        )
        |> Values.maybe_collect_error(
          MapSet.member?(step_runs, node.node_id) and complete_run?,
          "workflow step node #{node.node_id} cannot declare complete_run"
        )
        |> Values.maybe_collect_error(
          terminal_sink? and Map.get(outgoing, node.node_id, 0) > 0,
          "terminal sink #{node.node_id} must not have outgoing edges"
        )
      end)

    Values.add_errors(errors, completion_errors)
  end

  defp contains_completion_key?(map, target_key) when is_map(map) do
    Enum.any?(map, fn
      {^target_key, _value} ->
        true

      {_key, value} when is_map(value) ->
        contains_completion_key?(value, target_key)

      {_key, value} when is_list(value) ->
        Enum.any?(value, &contains_completion_key?(&1, target_key))

      _other ->
        false
    end)
  end

  defp contains_completion_key?(_value, _target_key), do: false

  defp valid_output_message_type?(value), do: is_binary(value) and value != ""

  defp completion_threshold?(value) when is_integer(value), do: value > 0

  defp completion_threshold?(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int > 0
      _ -> false
    end
  end

  defp completion_threshold?(_value), do: false

  defp outgoing_edge_counts(manifest) do
    Enum.reduce(manifest.edges, %{}, fn edge, acc ->
      Map.update(acc, edge.from_node, 1, &(&1 + 1))
    end)
  end

  defp workflow_step_run_ids(manifest) do
    flow = if is_map(manifest.flow), do: manifest.flow, else: %{}
    steps = Map.get(flow, "steps", [])

    if is_list(steps) do
      steps
      |> Enum.filter(&is_map/1)
      |> Enum.map(&workflow_step_run_id/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  @doc false
  def workflow_step_run_id(step) do
    reference =
      case step["run"] do
        %{} = run -> run["agent"] || step["agent_id"] || run["binding"]
        scalar -> scalar
      end

    case reference || step["id"] do
      value when is_binary(value) -> value
      value when is_atom(value) or is_integer(value) -> to_string(value)
      _ -> ""
    end
  end
end
