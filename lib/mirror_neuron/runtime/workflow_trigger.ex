defmodule MirrorNeuron.Runtime.WorkflowTrigger do
  @moduledoc false

  @aliases %{
    "all_required" => "all_success",
    "all_success" => "all_success",
    "all_done" => "all_done",
    "any_success" => "one_success",
    "one_success" => "one_success",
    "any_done" => "one_done",
    "one_done" => "one_done",
    "any_failed" => "one_failed",
    "one_failed" => "one_failed",
    "partial_success" => "none_failed_min_one_success",
    "none_failed_min_one_success" => "none_failed_min_one_success",
    "quorum" => "quorum_success",
    "quorum_success" => "quorum_success"
  }

  def supported_rules do
    @aliases
    |> Map.values()
    |> Enum.uniq()
  end

  def normalize(value, opts \\ []) do
    default = Keyword.get(opts, :default, "all_success")

    {rule, quorum} =
      case value do
        value when is_binary(value) ->
          {value, nil}

        %{} = value ->
          {
            Map.get(value, "rule") || Map.get(value, "type") || Map.get(value, "mode"),
            Map.get(value, "quorum") || Map.get(value, "count") || Map.get(value, "minimum")
          }

        _ ->
          {default, nil}
      end

    rule = Map.get(@aliases, to_string(rule || default))

    cond do
      is_nil(rule) ->
        {:error, "unsupported trigger rule #{inspect(value)}"}

      rule == "quorum_success" and not positive_integer?(quorum) ->
        {:error, "trigger rule quorum_success requires a positive quorum"}

      true ->
        {:ok, %{"rule" => rule, "quorum" => normalize_quorum(quorum)}}
    end
  end

  def from_step(step, graph \\ %{})

  def from_step(step, graph) when is_map(step) do
    control = Map.get(step, "control")
    control = if is_map(control), do: control, else: %{}
    join = Map.get(step, "join")
    join = if is_map(join), do: join, else: %{}

    value =
      Map.get(step, "trigger_rule") ||
        Map.get(control, "trigger_rule") ||
        Map.get(join, "trigger_rule") ||
        join_rule(join) ||
        Map.get(graph, "join_default") ||
        "all_success"

    value =
      if is_map(value) and Map.get(value, "quorum") in [nil, ""] do
        Map.put(value, "quorum", Map.get(step, "quorum") || Map.get(control, "quorum"))
      else
        value
      end

    value =
      if value in ["quorum", "quorum_success"] do
        %{
          "rule" => value,
          "quorum" =>
            Map.get(step, "quorum") || Map.get(control, "quorum") || Map.get(join, "quorum")
        }
      else
        value
      end

    normalize(value)
  end

  def from_step(_step, _graph), do: normalize(nil)

  defp join_rule(join) do
    Map.get(join, "rule") || Map.get(join, "mode")
  end

  defp positive_integer?(value) when is_integer(value), do: value > 0

  defp positive_integer?(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer > 0
      _ -> false
    end
  end

  defp positive_integer?(_value), do: false

  defp normalize_quorum(value) when is_integer(value) and value > 0, do: value

  defp normalize_quorum(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp normalize_quorum(_value), do: nil
end
