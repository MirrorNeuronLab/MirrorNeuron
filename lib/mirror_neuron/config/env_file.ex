defmodule MirrorNeuron.Config.EnvFile do
  @moduledoc false

  @key_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  def load_file(path, protected_keys) do
    if File.regular?(path) do
      path
      |> parse_file()
      |> Enum.each(fn {key, value} ->
        unless MapSet.member?(protected_keys, key) do
          System.put_env(key, value)
        end
      end)

      {:ok, path}
    else
      :missing
    end
  end

  def parse_file(path) do
    path
    |> File.read!()
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} -> parse_line(line, path, line_no) end)
  end

  defp parse_line(line, path, line_no) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        []

      true ->
        line
        |> strip_export()
        |> parse_assignment(path, line_no)
    end
  end

  defp strip_export("export " <> rest), do: String.trim_leading(rest)
  defp strip_export(line), do: line

  defp parse_assignment(line, path, line_no) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)

        unless Regex.match?(@key_pattern, key) do
          raise ArgumentError, "#{path}:#{line_no} has invalid environment key #{inspect(key)}"
        end

        [{key, parse_value(String.trim(raw_value))}]

      _ ->
        raise ArgumentError, "#{path}:#{line_no} must be KEY=VALUE"
    end
  end

  defp parse_value("\"" <> rest) do
    {value, _tail} = take_quoted(rest, ?", "")

    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp parse_value("'" <> rest) do
    {value, _tail} = take_quoted(rest, ?', "")
    value
  end

  defp parse_value(value) do
    value
    |> strip_inline_comment()
    |> String.trim()
  end

  defp take_quoted(<<quote, rest::binary>>, quote, acc), do: {acc, rest}

  defp take_quoted(<<"\\", char, rest::binary>>, quote, acc),
    do: take_quoted(rest, quote, acc <> <<?\\, char>>)

  defp take_quoted(<<char, rest::binary>>, quote, acc),
    do: take_quoted(rest, quote, acc <> <<char>>)

  defp take_quoted(<<>>, quote, _acc) do
    raise ArgumentError, "unterminated quoted value ending with #{<<quote>>}"
  end

  defp strip_inline_comment(value) do
    case :binary.match(value, " #") do
      {index, _length} -> binary_part(value, 0, index)
      :nomatch -> value
    end
  end
end
