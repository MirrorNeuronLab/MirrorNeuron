defmodule MirrorNeuron.ServiceCheck.Probes do
  @moduledoc false

  alias MirrorNeuron.ServiceCheck.Redaction

  def run(check, service, timeout) do
    case Map.get(check, "type") do
      "http" -> http_check(check, service, timeout)
      "tcp" -> tcp_check(check, service, timeout)
      "script" -> script_check()
      "grpc" -> grpc_check(check, service, timeout)
      other -> {:error, "unsupported service check type #{inspect(other)}"}
    end
  end

  defp http_check(check, service, timeout) do
    with {:ok, url} <- check_url(check, service),
         {:ok, method} <- http_method(check),
         :ok <- ensure_http_started(),
         {:ok, response} <- request_http(method, url, check, timeout) do
      validate_http_response(response, check, url)
    end
  end

  defp tcp_check(check, service, timeout) do
    with {:ok, address, port} <- address_port(check, service) do
      case :gen_tcp.connect(String.to_charlist(address), port, [:binary, active: false], timeout) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          {:ok, %{"address" => address, "port" => port}}

        {:error, reason} ->
          {:error, "tcp connect failed for #{address}:#{port}: #{inspect(reason)}"}
      end
    end
  end

  defp script_check() do
    {:error,
     "script service checks are owned by mn-python-sdk/API/CLI; advertise a concrete service health result before Core checks it"}
  end

  defp grpc_check(check, service, timeout) do
    with {:ok, address, port} <- address_port(check, service) do
      target = "#{address}:#{port}"

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

  defp request_http(method, url, check, timeout) when method in [:get, :head] do
    headers = http_headers(check)
    request = {String.to_charlist(url), headers}
    response = :httpc.request(method, request, http_options(timeout), body_options())
    normalize_httpc_response(response)
  end

  defp request_http(method, url, check, timeout) do
    headers = http_headers(check)
    body = to_string(Map.get(check, "body") || "")
    content_type = to_string(Map.get(check, "content_type") || "application/json")
    request = {String.to_charlist(url), headers, String.to_charlist(content_type), body}
    response = :httpc.request(method, request, http_options(timeout), body_options())
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
         "http #{Redaction.url(url)} returned #{status}, expected #{format_expected(expected)}"}

      contains = Map.get(check, "contains") ->
        if String.contains?(to_string(body), to_string(contains)) do
          {:ok, %{"url" => Redaction.url(url), "status" => status}}
        else
          {:error, "http #{Redaction.url(url)} did not contain expected text"}
        end

      true ->
        {:ok, %{"url" => Redaction.url(url), "status" => status}}
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

  defp http_options(timeout), do: [timeout: timeout, connect_timeout: timeout]
  defp body_options, do: [body_format: :binary]

  defp http_headers(%{"headers" => headers}) when is_map(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(to_string(value))}
    end)
  end

  defp http_headers(_check), do: []

  defp parse_port(value) when is_integer(value) and value >= 1 and value <= 65_535, do: value

  defp parse_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port >= 1 and port <= 65_535 -> port
      _ -> nil
    end
  end

  defp parse_port(_value), do: nil

  defp normalize_path(path) do
    path = to_string(path || "/")
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end
end
