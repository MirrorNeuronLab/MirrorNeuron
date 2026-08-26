defmodule MirrorNeuron.ServiceCheck do
  @moduledoc false

  alias MirrorNeuron.ServiceSpec

  @sensitive_keys ~w(authorization cookie token access_token api_key key password secret signature sig)
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

  def run_check(check, service, opts) when is_map(check) do
    check = stringify_map(check)
    service = stringify_map(service)
    started = System.monotonic_time(:millisecond)

    result =
      case Map.get(check, "type") do
        "http" -> http_check(check, service)
        "tcp" -> tcp_check(check, service)
        "script" -> script_check(check, service, opts)
        "grpc" -> grpc_check(check, service)
        other -> {:error, "unsupported service check type #{inspect(other)}"}
      end

    duration_ms = System.monotonic_time(:millisecond) - started
    normalize_result(result, check, duration_ms)
  end

  def run_check(_check, _service, _opts),
    do: critical_result("check", "service check must be an object")

  def redact_value(value), do: do_redact_value(value, "")

  defp http_check(check, service) do
    with {:ok, url} <- check_url(check, service),
         {:ok, method} <- http_method(check),
         :ok <- ensure_http_started(),
         {:ok, response} <- request_http(method, url, check) do
      validate_http_response(response, check, url)
    end
  end

  defp tcp_check(check, service) do
    with {:ok, address, port} <- address_port(check, service) do
      timeout = timeout_ms(check)

      case :gen_tcp.connect(String.to_charlist(address), port, [:binary, active: false], timeout) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          {:ok, %{"address" => address, "port" => port}}

        {:error, reason} ->
          {:error, "tcp connect failed for #{address}:#{port}: #{inspect(reason)}"}
      end
    end
  end

  defp script_check(_check, _service, _opts) do
    {:error,
     "script service checks are owned by mn-python-sdk/API/CLI; advertise a concrete service health result before Core checks it"}
  end

  defp grpc_check(check, service) do
    with {:ok, address, port} <- address_port(check, service) do
      target = "#{address}:#{port}"
      timeout = timeout_ms(check)

      connect_opts = [adapter_opts: [connect_timeout: timeout, retry: 0]]

      case GRPC.Stub.connect(target, connect_opts) do
        {:ok, channel} ->
          try do
            run_grpc_check(channel, check, target, timeout)
          after
            disconnect_grpc_channel(channel)
          end

        {:error, reason} ->
          grpc_check_error(target, reason)
      end
    end
  end

  defp run_grpc_check(channel, check, target, timeout) do
    request = %Grpc.Health.V1.HealthCheckRequest{
      service: to_string(Map.get(check, "service") || "")
    }

    case Grpc.Health.V1.Health.Stub.check(channel, request, timeout: timeout) do
      {:ok, %{status: :SERVING}} ->
        {:ok, %{"target" => target, "serving_status" => "SERVING"}}

      {:ok, response} ->
        {:error, "grpc health status #{inspect(response.status)}"}

      {:error, reason} ->
        grpc_check_error(target, reason)
    end
  end

  defp grpc_check_error(target, %GRPC.RPCError{} = error),
    do: {:error, "grpc health check failed for #{target}: #{Exception.message(error)}"}

  defp grpc_check_error(target, reason),
    do: {:error, "grpc health check failed for #{target}: #{inspect(reason)}"}

  defp disconnect_grpc_channel(channel) do
    _ = GRPC.Stub.disconnect(channel)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp check_url(check, service) do
    case Map.get(check, "url") do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _ ->
        with {:ok, address, port} <- address_port(check, service) do
          scheme = Map.get(check, "scheme") || Map.get(service, "scheme") || "http"
          path = Map.get(check, "path") || "/"
          {:ok, "#{scheme}://#{address}:#{port}#{normalize_path(path)}"}
        end
    end
  end

  defp http_method(check) do
    method = check |> Map.get("method", "GET") |> to_string() |> String.upcase()

    case method do
      "GET" -> {:ok, :get}
      "HEAD" -> {:ok, :head}
      "POST" -> {:ok, :post}
      "PUT" -> {:ok, :put}
      "PATCH" -> {:ok, :patch}
      other -> {:error, "unsupported http check method #{other}"}
    end
  end

  defp ensure_http_started do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp request_http(method, url, check) when method in [:get, :head] do
    headers = http_headers(check)
    request = {String.to_charlist(url), headers}
    response = :httpc.request(method, request, http_options(check), body_options())
    normalize_httpc_response(response)
  end

  defp request_http(method, url, check) do
    headers = http_headers(check)
    body = to_string(Map.get(check, "body") || "")
    content_type = to_string(Map.get(check, "content_type") || "application/json")
    request = {String.to_charlist(url), headers, String.to_charlist(content_type), body}
    response = :httpc.request(method, request, http_options(check), body_options())
    normalize_httpc_response(response)
  end

  defp normalize_httpc_response({:ok, {{_version, status, _reason}, headers, body}}),
    do: {:ok, %{status: status, headers: headers, body: to_string(body)}}

  defp normalize_httpc_response({:error, reason}),
    do: {:error, "http request failed: #{inspect(reason)}"}

  defp normalize_httpc_response(other), do: {:error, "http request failed: #{inspect(other)}"}

  defp validate_http_response(%{status: status, body: body}, check, url) do
    expected = expected_statuses(check)

    cond do
      status not in expected ->
        {:error,
         "http #{redact_url(url)} returned #{status}, expected #{format_expected(expected)}"}

      contains = Map.get(check, "contains") ->
        if String.contains?(to_string(body), to_string(contains)) do
          {:ok, %{"url" => redact_url(url), "status" => status}}
        else
          {:error, "http #{redact_url(url)} did not contain expected text"}
        end

      true ->
        {:ok, %{"url" => redact_url(url), "status" => status}}
    end
  end

  defp address_port(check, service) do
    address = Map.get(check, "address") || Map.get(service, "address")
    port = parse_port(Map.get(check, "port") || Map.get(service, "port"))

    cond do
      not (is_binary(address) and address != "") ->
        {:error, "service check requires address"}

      is_nil(port) ->
        {:error, "service check requires port"}

      true ->
        {:ok, address, port}
    end
  end

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

  defp expected_statuses(%{"expected_status" => statuses}) when is_list(statuses),
    do: Enum.flat_map(statuses, &expand_status/1)

  defp expected_statuses(%{"expected_status" => status}), do: expand_status(status)
  defp expected_statuses(_check), do: Enum.to_list(200..399)

  defp expand_status(status) when is_integer(status), do: [status]

  defp expand_status(status) when is_binary(status) do
    case String.split(status, ["..", "-"], parts: 2) do
      [left, right] ->
        with {from, ""} <- Integer.parse(String.trim(left)),
             {to, ""} <- Integer.parse(String.trim(right)) do
          Enum.to_list(from..to)
        else
          _ -> []
        end

      [single] ->
        case Integer.parse(String.trim(single)) do
          {parsed, ""} -> [parsed]
          _ -> []
        end
    end
  end

  defp expand_status(_status), do: []

  defp format_expected(statuses) when length(statuses) > 8,
    do: "#{List.first(statuses)}..#{List.last(statuses)}"

  defp format_expected(statuses), do: Enum.join(statuses, ",")

  defp http_options(check), do: [timeout: timeout_ms(check), connect_timeout: timeout_ms(check)]
  defp body_options, do: [body_format: :binary]

  defp http_headers(check) do
    check
    |> Map.get("headers", %{})
    |> stringify_map()
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(to_string(value))}
    end)
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

  defp parse_port(value) when is_integer(value) and value >= 1 and value <= 65_535, do: value

  defp parse_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port >= 1 and port <= 65_535 -> port
      _ -> nil
    end
  end

  defp parse_port(_value), do: nil

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp normalize_path(path) do
    path = to_string(path || "/")
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  defp check_name(check),
    do: to_string(Map.get(check, "name") || Map.get(check, "type") || "check")

  defp redact_url(url) do
    uri = URI.parse(to_string(url))

    redacted_query =
      if is_binary(uri.query) and uri.query != "" do
        uri.query
        |> URI.decode_query()
        |> Enum.map(fn {key, value} ->
          if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, value}
        end)
        |> URI.encode_query()
      else
        nil
      end

    %{uri | query: redacted_query}
    |> URI.to_string()
  rescue
    _ -> "[REDACTED_URL]"
  end

  defp do_redact_value(value, path) when is_map(value) do
    Map.new(value, fn {key, item} ->
      key = to_string(key)
      next_path = if path == "", do: key, else: "#{path}.#{key}"
      {key, if(sensitive_key?(key), do: "[REDACTED]", else: do_redact_value(item, next_path))}
    end)
  end

  defp do_redact_value(value, path) when is_list(value),
    do: Enum.map(value, &do_redact_value(&1, path))

  defp do_redact_value(value, path) when is_binary(value) do
    if String.starts_with?(value, ["http://", "https://"]) do
      redact_url(value)
    else
      if sensitive_key?(path), do: "[REDACTED]", else: value
    end
  end

  defp do_redact_value(value, _path), do: value

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_keys, &String.contains?(key, &1))
  end

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
