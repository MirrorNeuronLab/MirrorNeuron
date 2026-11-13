defmodule MirrorNeuron.ResourceSpec.Values do
  @moduledoc "Scalar parsing and map normalization shared by resource schemas."

  def number_value(value) when is_integer(value), do: value

  def number_value(value) when is_float(value), do: value

  def number_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      {number, _rest} -> number
      :error -> nil
    end
  end

  def number_value(_value), do: nil

  def integer_value(value) when is_integer(value), do: value

  def integer_value(value) when is_float(value), do: trunc(value)

  def integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  def integer_value(_value), do: nil

  def normalize_comparison_operator(nil), do: nil

  def normalize_comparison_operator(value)
      when is_binary(value) or is_atom(value) or is_number(value) do
    case value |> to_string() |> String.trim() do
      operator when operator in [">", ">=", "=="] -> operator
      "=" -> "=="
      _other -> nil
    end
  end

  def normalize_comparison_operator(_value), do: nil

  def kind_from_type(nil), do: nil

  def kind_from_type(type) do
    type = String.downcase(to_string(type))

    cond do
      String.contains?(type, "gpu") -> "gpu"
      String.contains?(type, "fpga") -> "fpga"
      String.contains?(type, "tpu") -> "tpu"
      true -> nil
    end
  end

  def auto_port?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) == "auto"

  def auto_port?(_value), do: false

  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: String.downcase(value)
  end

  def trim_to_nil(nil), do: nil

  def trim_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end

  def list_value(value) when is_list(value), do: Enum.map(value, &to_string/1)

  def list_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def list_value(nil), do: []

  def list_value(value), do: [to_string(value)]

  def map_get(map, key), do: MirrorNeuron.SafeAccess.map_get(map, key)

  def stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  def stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value), do: value
end
