defmodule MirrorNeuron.ServiceCheck do
  @moduledoc false

  alias MirrorNeuron.ServiceCheck.{Probes, Redaction}
  alias MirrorNeuron.ServiceSpec

  @default_timeout_ms 2_000

  def check_service(service, opts \\ []) when is_map(service) do
    service = stringify_map(service)
    checks = Map.get(service, "checks", [])

    results =
      case checks do
        [] -> []
        checks when is_list(checks) -> Enum.map(checks, &run_check(&1, service, opts))
        _ -> [critical_result("checks", "service checks must be a list")]
      end

    status = aggregate_status(results)

    %{
      "service_id" => Map.get(service, "id"),
      "name" => Map.get(service, "name"),
      "status" => status,
      "checked_at" => timestamp(),
      "checks" => results
    }
  end

  def apply_failure_thresholds(service, health) when is_map(service) and is_map(health) do
    service = stringify_map(service)
    health = stringify_map(health)
    previous_counts = service |> Map.get("health_check_failures", %{}) |> stringify_map()
    check_specs = service |> Map.get("checks", []) |> check_specs_by_name()

    {checks, failure_counts} =
      health
      |> Map.get("checks", [])
      |> List.wrap()
      |> Enum.map_reduce(previous_counts, fn result, counts ->
        result = stringify_map(result)
        check_name = check_name(result)

        if Map.get(result, "status") == "critical" do
          count = parse_int(Map.get(counts, check_name), 0) + 1
          threshold = failure_threshold(Map.get(check_specs, check_name))

          result =
            result
            |> Map.put("consecutive_failures", count)
            |> Map.put("failures_before_critical", threshold)

          result =
            if count < threshold do
              result
              |> Map.put("status", "passing")
              |> Map.put("suppressed_status", "critical")
              |> Map.put("transient_failure", true)
            else
              result
            end

          {result, Map.put(counts, check_name, count)}
        else
          {result, Map.delete(counts, check_name)}
        end
      end)

    health =
      health
      |> Map.put("checks", checks)
      |> Map.put("status", aggregate_status(checks))

    {health, failure_counts}
  end

  def apply_failure_thresholds(_service, health), do: {stringify_map(health), %{}}

  def run_check(check, service, opts \\ [])

  def run_check(check, service, _opts) when is_map(check) do
    check = stringify_map(check)
    service = stringify_map(service)
    started = System.monotonic_time(:millisecond)

    result = Probes.run(check, service, timeout_ms(check))
    duration_ms = System.monotonic_time(:millisecond) - started
    normalize_result(result, check, duration_ms)
  end

  def run_check(_check, _service, _opts),
    do: critical_result("check", "service check must be an object")

  defdelegate redact_value(value), to: Redaction, as: :value

  defp normalize_result({:ok, details}, check, duration_ms) do
    %{
      "name" => check_name(check),
      "type" => Map.get(check, "type"),
      "required" => ServiceSpec.required?(check),
      "status" => "passing",
      "duration_ms" => duration_ms,
      "details" => redact_value(details)
    }
  end

  defp normalize_result({:error, reason}, check, duration_ms) do
    %{
      "name" => check_name(check),
      "type" => Map.get(check, "type"),
      "required" => ServiceSpec.required?(check),
      "status" => "critical",
      "duration_ms" => duration_ms,
      "error" => to_string(redact_value(reason))
    }
  end

  defp normalize_result(other, check, duration_ms),
    do: normalize_result({:error, inspect(other)}, check, duration_ms)

  defp aggregate_status([]), do: "passing"

  defp aggregate_status(results) do
    cond do
      Enum.any?(results, &(Map.get(&1, "status") == "critical" and Map.get(&1, "required", true))) ->
        "critical"

      Enum.any?(results, &(Map.get(&1, "status") == "critical")) ->
        "warning"

      true ->
        "passing"
    end
  end

  defp critical_result(name, reason) do
    %{
      "name" => name,
      "type" => "unknown",
      "required" => true,
      "status" => "critical",
      "duration_ms" => 0,
      "error" => reason
    }
  end

  defp timeout_ms(check), do: parse_int(Map.get(check, "timeout_ms"), @default_timeout_ms)

  defp check_specs_by_name(checks) when is_list(checks) do
    Map.new(checks, fn check ->
      check = stringify_map(check)
      {check_name(check), check}
    end)
  end

  defp check_specs_by_name(_checks), do: %{}

  defp failure_threshold(nil), do: 1
  defp failure_threshold(check), do: parse_int(Map.get(check, "failures_before_critical"), 1)

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp check_name(check),
    do: to_string(Map.get(check, "name") || Map.get(check, "type") || "check")

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
