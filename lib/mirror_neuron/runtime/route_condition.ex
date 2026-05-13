defmodule MirrorNeuron.Runtime.RouteCondition do
  @supported_routing_modes ["broadcast", "first_match", "all_match"]
  @operators ["==", "!=", ">", ">=", "<", "<=", "contains", "in", "exists"]
  @expr ~r/^\$\{([A-Za-z0-9_.-]+)\}\s*(==|!=|>=|<=|>|<|contains|in|exists)(?:\s+(.+))?$/

  alias MirrorNeuron.Message

  def supported_routing_modes, do: @supported_routing_modes

  def validate(nil), do: :ok
  def validate(condition) when condition == %{}, do: :ok

  def validate(%{"all" => conditions}) when is_list(conditions) do
    validate_many(conditions)
  end

  def validate(%{"any" => conditions}) when is_list(conditions) do
    validate_many(conditions)
  end

  def validate(%{"not" => condition}) when is_map(condition), do: validate(condition)

  def validate(%{"expr" => expression}) when is_binary(expression) do
    case Regex.run(@expr, String.trim(expression)) do
      nil -> {:error, "unsupported route condition expression #{inspect(expression)}"}
      [_full, _path, "exists"] -> :ok
      [_full, _path, _op, _value] -> :ok
    end
  end

  def validate(%{"path" => path, "op" => operator} = condition)
      when is_binary(path) and operator in @operators do
    if operator == "exists" or Map.has_key?(condition, "value") do
      :ok
    else
      {:error, "route condition for #{path} is missing value"}
    end
  end

  def validate(%{"path" => path}) when is_binary(path), do: :ok

  def validate(condition), do: {:error, "unsupported route condition #{inspect(condition)}"}

  def matches?(nil, _context), do: true
  def matches?(condition, _context) when condition == %{}, do: true

  def matches?(%{"all" => conditions}, context) when is_list(conditions) do
    Enum.all?(conditions, &matches?(&1, context))
  end

  def matches?(%{"any" => conditions}, context) when is_list(conditions) do
    Enum.any?(conditions, &matches?(&1, context))
  end

  def matches?(%{"not" => condition}, context) when is_map(condition) do
    not matches?(condition, context)
  end

  def matches?(%{"expr" => expression}, context) when is_binary(expression) do
    with {:ok, path, operator, expected} <- parse_expression(expression) do
      compare(resolve_path(context, path), operator, expected)
    else
      _ -> false
    end
  end

  def matches?(%{"path" => path} = condition, context) when is_binary(path) do
    operator = Map.get(condition, "op", "==")
    compare(resolve_path(context, path), operator, Map.get(condition, "value"))
  end

  def matches?(_condition, _context), do: false

  def context(message, payload, local_state) do
    agent_state = stringify_keys(local_state)

    %{
      "message" => %{
        "body" => Message.body(message),
        "headers" => Message.headers(message),
        "type" => Message.type(message),
        "class" => Message.class(message),
        "from" => Message.from(message),
        "to" => Message.to(message)
      },
      "payload" => payload,
      "state" => Map.get(agent_state, "delegate_state", agent_state),
      "agent_state" => agent_state
    }
  end

  def resolve_path(context, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(context, fn part, current -> resolve_part(current, part) end)
  end

  defp validate_many(conditions) do
    conditions
    |> Enum.reduce_while(:ok, fn
      condition, :ok when is_map(condition) ->
        case validate(condition) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _condition, :ok ->
        {:halt, {:error, "compound route conditions must contain maps"}}
    end)
  end

  defp parse_expression(expression) do
    case Regex.run(@expr, String.trim(expression)) do
      [_full, path, "exists"] -> {:ok, path, "exists", nil}
      [_full, path, operator, expected] -> {:ok, path, operator, parse_value(expected)}
      _ -> {:error, :unsupported_expression}
    end
  end

  defp parse_value(raw) do
    text = String.trim(raw)

    case Jason.decode(text) do
      {:ok, value} ->
        value

      {:error, _reason} ->
        text
        |> String.trim_leading("'")
        |> String.trim_trailing("'")
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")
    end
  end

  defp compare(actual, "exists", _expected), do: not is_nil(actual)
  defp compare(actual, "==", expected), do: actual == expected
  defp compare(actual, "!=", expected), do: actual != expected

  defp compare(actual, operator, expected) when operator in [">", ">=", "<", "<="] do
    with {:ok, left} <- to_number(actual),
         {:ok, right} <- to_number(expected) do
      case operator do
        ">" -> left > right
        ">=" -> left >= right
        "<" -> left < right
        "<=" -> left <= right
      end
    else
      _ -> false
    end
  end

  defp compare(actual, "contains", expected) when is_binary(actual),
    do: String.contains?(actual, to_string(expected))

  defp compare(actual, "contains", expected) when is_list(actual), do: expected in actual

  defp compare(actual, "contains", expected) when is_map(actual),
    do: Map.has_key?(actual, expected)

  defp compare(_actual, "contains", _expected), do: false

  defp compare(actual, "in", expected) when is_list(expected), do: actual in expected
  defp compare(_actual, "in", _expected), do: false
  defp compare(_actual, _operator, _expected), do: false

  defp resolve_part(nil, _part), do: nil

  defp resolve_part(current, part) when is_map(current) do
    cond do
      Map.has_key?(current, part) ->
        Map.get(current, part)

      Map.has_key?(current, String.to_existing_atom(part)) ->
        Map.get(current, String.to_existing_atom(part))

      true ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp resolve_part(current, part) when is_list(current) do
    case Integer.parse(part) do
      {index, ""} -> Enum.at(current, index)
      _ -> nil
    end
  end

  defp resolve_part(_current, _part), do: nil

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp to_number(value) when is_number(value), do: {:ok, value}

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp to_number(_value), do: :error
end
