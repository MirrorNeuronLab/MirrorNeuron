defmodule MirrorNeuron.BlueprintValidation.Reports do
  @moduledoc "Builds versioned validation reports with redacted, located issues."

  alias MirrorNeuron.BlueprintValidation.Redaction
  alias MirrorNeuron.BlueprintValidation.Values

  def validation_report(issues) do
    normalized = Enum.map(issues, &normalize_issue/1)

    %{
      "version" => "validation.report/v1",
      "ok" => false,
      "status" => "failed",
      "error_count" => length(normalized),
      "errors" => Enum.map(normalized, &issue_message/1),
      "issues" => normalized,
      "results" => []
    }
  end

  def issue(code, message, opts) do
    source = opts[:source]
    path = opts[:path]

    base = %{
      "code" => code,
      "message" => message,
      "help" => opts[:help] || "",
      "severity" => opts[:severity] || "error"
    }

    base
    |> maybe_put("location", location(source, path), source || path)
    |> maybe_put(
      "expected",
      Redaction.redact_value(opts[:expected], path),
      Keyword.has_key?(opts, :expected)
    )
    |> maybe_put(
      "actual",
      Redaction.redact_value(opts[:actual], path),
      Keyword.has_key?(opts, :actual)
    )
    |> maybe_put("rule", opts[:rule], opts[:rule])
    |> maybe_put("debug", Redaction.redact_value(opts[:debug], "debug"), opts[:debug])
  end

  defp normalize_issue(%{} = raw) do
    location = Values.map_value(Values.map_get(raw, "location"))
    source = Values.map_get(location, "source") || Values.map_get(raw, "source") || "validator"
    path = Values.map_get(location, "path") || Values.map_get(raw, "path") || ""

    issue(
      Values.map_get(raw, "code") || Values.map_get(raw, "type") || "validation.failed",
      Values.map_get(raw, "message") || Values.map_get(raw, "detail") ||
        Values.map_get(raw, "msg") ||
        "Validation failed",
      help:
        Values.map_get(raw, "help") || Values.map_get(raw, "fix") ||
          Values.map_get(raw, "suggestion") || "",
      severity: Values.map_get(raw, "severity") || "error",
      source: source,
      path: path,
      expected: Values.map_get(raw, "expected"),
      actual: MirrorNeuron.SafeAccess.map_get(raw, "actual", Values.map_get(raw, "input")),
      rule: Values.map_get(raw, "rule"),
      debug: Values.map_get(raw, "debug")
    )
    |> put_in_pointer(Values.map_get(location, "pointer"))
  end

  defp normalize_issue(other),
    do: issue("validation.failed", to_string(other), source: "validator")

  defp issue_message(issue) do
    location = Values.map_value(Values.map_get(issue, "location"))
    path = Values.map_get(location, "path")

    message =
      to_string(
        Values.map_get(issue, "message") || Values.map_get(issue, "code") || "Validation failed"
      )

    if is_binary(path) and path != "" and not String.contains?(message, path) do
      "#{path}: #{message}"
    else
      message
    end
  end

  defp location(source, path) do
    %{
      "source" => to_string(source || ""),
      "path" => to_string(path || ""),
      "pointer" => json_pointer(source, path)
    }
  end

  defp json_pointer(source, path) do
    parts =
      [source | String.split(to_string(path || ""), [".", "[", "]"], trim: true)]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(to_string(&1) == ""))
      |> Enum.map(&escape_pointer/1)

    "/" <> Enum.join(parts, "/")
  end

  defp escape_pointer(value) do
    value
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp put_in_pointer(issue, nil), do: issue

  defp put_in_pointer(issue, ""), do: issue

  defp put_in_pointer(issue, pointer) do
    update_in(issue, ["location"], fn location ->
      Map.put(Values.map_value(location), "pointer", to_string(pointer))
    end)
  end

  defp maybe_put(map, _key, _value, nil), do: map

  defp maybe_put(map, _key, _value, false), do: map

  defp maybe_put(map, key, value, _condition), do: Map.put(map, key, value)

  def rule_ref(rule) do
    %{
      "name" => Values.rule_name(rule),
      "type" => to_string(Values.map_get(rule, "type") || "")
    }
  end
end
