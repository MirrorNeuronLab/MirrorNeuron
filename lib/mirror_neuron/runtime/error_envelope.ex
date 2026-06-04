defmodule MirrorNeuron.Runtime.ErrorEnvelope do
  @moduledoc """
  Shared runtime error envelope for job, workflow, sandbox, scheduler, and recovery failures.
  """

  alias MirrorNeuron.Runtime

  @schema_version "mn.error.v1"
  @code_limit 128
  @desc_limit 160
  @message_limit 2 * 1024
  @remediation_limit 1024
  @envelope_limit 16 * 1024
  @redacted "[REDACTED]"
  @sensitive_key_fragments [
    "authorization",
    "cookie",
    "secret",
    "token",
    "password",
    "api_key",
    "apikey",
    "private_key",
    "credential"
  ]

  def schema_version, do: @schema_version

  def normalize(reason, opts \\ []) do
    envelope = envelope_from(reason, opts)

    if byte_size(json(envelope)) <= @envelope_limit do
      envelope
    else
      compact_envelope(envelope)
    end
  end

  def desc(%{"desc" => desc}) when is_binary(desc), do: desc
  def desc(%{desc: desc}) when is_binary(desc), do: desc
  def desc(reason), do: normalize(reason)["desc"]

  def error?(%{"schema_version" => @schema_version}), do: true
  def error?(%{schema_version: @schema_version}), do: true
  def error?(_value), do: false

  defp envelope_from(%{"schema_version" => @schema_version} = error, opts) do
    error
    |> stringify_keys()
    |> normalize_existing(opts)
  end

  defp envelope_from(%{schema_version: @schema_version} = error, opts) do
    error
    |> stringify_keys()
    |> normalize_existing(opts)
  end

  defp envelope_from(reason, opts) do
    now = keyword(opts, :occurred_at) || Runtime.timestamp()
    message = reason_message(reason)
    code = keyword(opts, :code) || code_for(reason, opts)
    category = keyword(opts, :category) || category_for(code, message)
    desc = keyword(opts, :desc) || desc_for(code, message)
    retryable = retryable?(keyword(opts, :retryable), category, code)

    details =
      %{
        "message" => truncate_value(message, @message_limit),
        "category" => category,
        "retryable" => retryable,
        "reason_type" => reason_type(reason)
      }
      |> Map.merge(extract_details(reason))
      |> put_optional("component", keyword(opts, :component))
      |> put_optional("step_id", keyword(opts, :step_id))
      |> put_optional("agent_id", keyword(opts, :agent_id))
      |> put_optional("attempt", keyword(opts, :attempt))
      |> put_optional("max_attempts", keyword(opts, :max_attempts))
      |> put_optional("node", keyword(opts, :node))
      |> redact()

    %{
      "schema_version" => @schema_version,
      "code" => truncate_string(to_string(code), @code_limit),
      "desc" => truncate_string(to_string(desc), @desc_limit),
      "details" => details,
      "severity" => keyword(opts, :severity) || "ERROR",
      "occurred_at" => now,
      "event_id" => keyword(opts, :event_id) || unique_id("evt"),
      "trace_id" => keyword(opts, :trace_id),
      "span_id" => keyword(opts, :span_id),
      "remediation" => truncate_string(remediation_for(code, category), @remediation_limit),
      "links" => links(keyword(opts, :links))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_existing(error, opts) do
    details = Map.get(error, "details")

    error
    |> Map.put("schema_version", @schema_version)
    |> Map.put(
      "code",
      truncate_string(
        to_string(Map.get(error, "code") || keyword(opts, :code) || "runtime.failure"),
        @code_limit
      )
    )
    |> Map.put(
      "desc",
      truncate_string(to_string(Map.get(error, "desc") || reason_message(error)), @desc_limit)
    )
    |> Map.put(
      "details",
      if(is_map(details), do: redact(details), else: %{"message" => reason_message(error)})
    )
    |> Map.put_new("severity", keyword(opts, :severity) || "ERROR")
    |> Map.put_new("occurred_at", keyword(opts, :occurred_at) || Runtime.timestamp())
    |> Map.put_new("event_id", keyword(opts, :event_id) || unique_id("evt"))
    |> Map.put_new(
      "remediation",
      truncate_string(
        remediation_for(Map.get(error, "code"), Map.get(error, "category")),
        @remediation_limit
      )
    )
    |> Map.put_new("links", links(keyword(opts, :links)))
  end

  defp compact_envelope(error) do
    details = Map.get(error, "details")
    message = if is_map(details), do: Map.get(details, "message"), else: nil

    error
    |> Map.put("details", %{
      "message" => truncate_value(message || Map.get(error, "desc") || "failure", @message_limit),
      "truncated" => true
    })
    |> Map.put("links", links(Map.get(error, "links")))
  end

  defp code_for(reason, opts) do
    cond do
      code = code_from_map(reason) ->
        code

      keyword(opts, :component) == "job_runner" ->
        "runtime.job_runner.failed"

      keyword(opts, :component) == "job_coordinator" ->
        "runtime.job.failed"

      match_text?(reason, ["heartbeat"]) ->
        "workflow.step.heartbeat_timeout"

      match_text?(reason, ["deadline", "timeout", "timed out"]) ->
        "workflow.step.timeout"

      match_text?(reason, ["retry", "exhaust"]) ->
        "workflow.step.retry_exhausted"

      match_text?(reason, ["lease"]) ->
        "scheduler.lease_unavailable"

      true ->
        "runtime.failure"
    end
  end

  defp desc_for(code, message) do
    case to_string(code) do
      "workflow.step.timeout" -> "Workflow step timed out"
      "workflow.step.heartbeat_timeout" -> "Workflow step missed heartbeat deadline"
      "workflow.step.retry_exhausted" -> "Workflow step exhausted retries"
      "scheduler.lease_unavailable" -> "Scheduler lease unavailable"
      "runtime.job_runner.failed" -> "Job runner failed"
      "runtime.job.failed" -> "Runtime job failed"
      _ -> humanize_message(message)
    end
  end

  defp remediation_for(code, category) do
    case {to_string(code || ""), to_string(category || "")} do
      {"workflow.step.timeout", _} ->
        "Check agent heartbeat, runtime node health, and step timeout settings."

      {"workflow.step.heartbeat_timeout", _} ->
        "Check agent heartbeat, runtime node health, and step timeout settings."

      {"workflow.step.retry_exhausted", _} ->
        "Review the failed step attempts, agent logs, inputs, and retry policy."

      {"scheduler.lease_unavailable", _} ->
        "Check scheduler lease ownership, Redis connectivity, and runtime node health."

      {"runtime.job_runner.failed", _} ->
        "Check runtime node health, job lease state, and coordinator startup logs."

      {_, "timeout"} ->
        "Check runtime health, timeout settings, and recent agent activity."

      _ ->
        "Review errors.jsonl, events.jsonl, logs.jsonl, and the failing step or agent context."
    end
  end

  defp category_for(code, message) do
    cond do
      match_text?(code, ["timeout"]) or match_text?(message, ["deadline", "timeout", "heartbeat"]) ->
        "timeout"

      match_text?(code, ["lease", "scheduler"]) ->
        "scheduler"

      match_text?(message, ["validation", "invalid"]) ->
        "validation"

      match_text?(message, ["cancel"]) ->
        "cancelled"

      true ->
        "runtime"
    end
  end

  defp retryable?(nil, "timeout", _code), do: false

  defp retryable?(nil, _category, code),
    do: match_text?(code, ["lease", "temporary", "unavailable"])

  defp retryable?(value, _category, _code), do: value in [true, "true", "yes", 1, "1"]

  defp reason_message(%{"message" => message}) when is_binary(message), do: message
  defp reason_message(%{message: message}) when is_binary(message), do: message
  defp reason_message(%{"reason" => reason}) when is_binary(reason), do: reason
  defp reason_message(%{reason: reason}) when is_binary(reason), do: reason
  defp reason_message(%{"desc" => desc}) when is_binary(desc), do: desc
  defp reason_message(%{desc: desc}) when is_binary(desc), do: desc
  defp reason_message(reason) when is_binary(reason), do: reason
  defp reason_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_message(reason), do: inspect(reason, limit: 50, printable_limit: 2_048)

  defp reason_type(reason) when is_binary(reason), do: "string"
  defp reason_type(reason) when is_atom(reason), do: "atom"
  defp reason_type(reason) when is_tuple(reason), do: "tuple"
  defp reason_type(reason) when is_map(reason), do: "map"
  defp reason_type(reason) when is_list(reason), do: "list"
  defp reason_type(_reason), do: "term"

  defp extract_details(reason) when is_map(reason) do
    reason
    |> stringify_keys()
    |> Map.drop([
      "schema_version",
      "code",
      "desc",
      "details",
      "severity",
      "occurred_at",
      "event_id",
      "trace_id",
      "span_id",
      "remediation",
      "links"
    ])
    |> truncate_values()
  end

  defp extract_details(_reason), do: %{}

  defp code_from_map(reason) when is_map(reason) do
    map = stringify_keys(reason)
    Map.get(map, "code") || Map.get(map, "error_code")
  end

  defp code_from_map(_reason), do: nil

  defp links(links) when is_list(links) do
    if Enum.empty?(links), do: default_links(), else: links
  end

  defp links(_links), do: default_links()

  defp default_links do
    [
      %{"rel" => "errors", "artifact_id" => "errors_jsonl"},
      %{"rel" => "events", "artifact_id" => "events_jsonl"},
      %{"rel" => "logs", "artifact_id" => "logs_jsonl"}
    ]
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp keyword(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp keyword(_opts, _key), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), value}
    end)
  end

  defp truncate_values(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), truncate_value(item, @message_limit)} end)
  end

  defp truncate_values(value), do: value

  defp truncate_value(value, limit) when is_binary(value), do: truncate_object(value, limit)
  defp truncate_value(value, limit) when is_map(value), do: truncate_map(value, limit)

  defp truncate_value(value, limit) when is_list(value),
    do: Enum.map(Enum.take(value, 25), &truncate_value(&1, limit))

  defp truncate_value(value, _limit), do: value

  defp truncate_map(value, limit) do
    Map.new(value, fn {key, item} -> {to_string(key), truncate_value(item, limit)} end)
  end

  defp truncate_string(value, limit) when is_binary(value) do
    if String.length(value) <= limit do
      value
    else
      String.slice(value, 0, limit)
    end
  end

  defp truncate_object(value, limit) when is_binary(value) do
    if String.length(value) <= limit do
      value
    else
      preview =
        value
        |> String.slice(0, max(limit - 128, 0))
        |> String.replace(~r/\s+/, " ")

      %{"truncated" => true, "chars" => String.length(value), "preview" => preview}
    end
  end

  defp redact(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      text_key = to_string(key)

      if sensitive_key?(text_key) do
        {text_key, @redacted}
      else
        {text_key, redact(item)}
      end
    end)
  end

  defp redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  defp redact(value), do: value

  defp sensitive_key?(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp humanize_message(message) do
    message
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Runtime failure"
      text -> String.capitalize(text)
    end
  end

  defp match_text?(value, terms) do
    text = value |> reason_message() |> String.downcase()
    Enum.any?(terms, &String.contains?(text, &1))
  end

  defp json(value), do: Jason.encode!(value)

  defp unique_id(prefix) do
    bytes = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "#{prefix}_#{bytes}"
  end
end
