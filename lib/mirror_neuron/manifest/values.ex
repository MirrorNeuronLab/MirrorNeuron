defmodule MirrorNeuron.Manifest.Values do
  @moduledoc "Shared JSON projection and error accumulation for manifest contracts."

  def json_safe(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, json_safe(value)}
    end)
  end

  def json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  def json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value

  def json_safe(nil), do: nil

  def json_safe(value) when is_atom(value), do: Atom.to_string(value)

  def json_safe(value), do: inspect(value)

  def maybe_add_error(errors, true, message), do: [message | errors]

  def maybe_add_error(errors, false, _message), do: errors

  def nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""

  def nonempty_string?(_value), do: false

  def maybe_collect_error(errors, true, message), do: [message | errors]

  def maybe_collect_error(errors, false, _message), do: errors

  def add_errors(errors, new_errors), do: Enum.reverse(new_errors) ++ errors
end
