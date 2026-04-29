defmodule MirrorNeuron.ContextEnginePreflight do
  @moduledoc false

  @default_timeout_ms 500
  @default_endpoints ["localhost:50052", "127.0.0.1:50052", "host.docker.internal:50052"]

  def ensure_available(required?) when required? in [false, nil], do: :ok

  def ensure_available(true) do
    timeout = timeout_ms()

    case first_available_endpoint(endpoints(), timeout) do
      {:ok, _endpoint} ->
        :ok

      {:error, attempts} ->
        {:error,
         "Context Engine is required by manifest requiredContextEngine=true, but it is not reachable. " <>
           "Start it on port 50052 or set CONTEXT_ENGINE_ADDR. Tried: #{format_attempts(attempts)}"}
    end
  end

  defp first_available_endpoint(endpoints, timeout) do
    Enum.reduce_while(endpoints, {:error, []}, fn endpoint, {:error, attempts} ->
      case available?(endpoint, timeout) do
        :ok -> {:halt, {:ok, endpoint}}
        {:error, reason} -> {:cont, {:error, attempts ++ [{endpoint, reason}]}}
      end
    end)
  end

  defp available?(endpoint, timeout) do
    with {:ok, host, port} <- parse_endpoint(endpoint),
         {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], timeout) do
      :gen_tcp.close(socket)
      :ok
    else
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  end

  defp endpoints do
    configured =
      "CONTEXT_ENGINE_ADDR"
      |> System.get_env("")
      |> String.trim()

    if configured == "" do
      @default_endpoints
    else
      [configured]
    end
  end

  defp timeout_ms do
    case Integer.parse(System.get_env("CONTEXT_ENGINE_READY_TIMEOUT_MS", "")) do
      {value, ""} when value > 0 ->
        value

      _ ->
        case Float.parse(System.get_env("CONTEXT_ENGINE_READY_TIMEOUT_SECONDS", "")) do
          {value, ""} when value > 0 -> round(value * 1000)
          _ -> @default_timeout_ms
        end
    end
  end

  defp parse_endpoint(endpoint) do
    endpoint = endpoint |> to_string() |> String.trim() |> String.replace_prefix("http://", "")
    endpoint = String.replace_prefix(endpoint, "https://", "")

    case String.split(endpoint, ":", parts: 2) do
      [host, port_text] ->
        case Integer.parse(port_text) do
          {port, ""} when host != "" and port > 0 and port <= 65_535 ->
            {:ok, host, port}

          _ ->
            {:error, "invalid endpoint"}
        end

      _ ->
        {:error, "invalid endpoint"}
    end
  end

  defp format_attempts(attempts) do
    attempts
    |> Enum.map(fn {endpoint, reason} -> "#{endpoint}: #{inspect(reason)}" end)
    |> Enum.join("; ")
  end
end
