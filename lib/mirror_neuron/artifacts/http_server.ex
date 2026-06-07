defmodule MirrorNeuron.Artifacts.HttpServer do
  @moduledoc false

  use GenServer
  require Logger

  alias MirrorNeuron.Artifacts.{BlobStore, Registry}

  @default_port 55_660
  @max_header_bytes 16_384
  @send_chunk_size 1_048_576
  @sha256_re ~r/^[a-f0-9]{64}$/

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    if enabled?(opts) do
      port = port(opts)
      bind_host = bind_host(opts)

      case :gen_tcp.listen(port, [
             :binary,
             active: false,
             packet: :raw,
             reuseaddr: true,
             ip: bind_ip(bind_host)
           ]) do
        {:ok, listener} ->
          Logger.info("MirrorNeuron artifact service listening on #{bind_host}:#{port}")
          send(self(), :accept)
          {:ok, %{listener: listener, port: port, bind_host: bind_host}}

        {:error, reason} ->
          {:stop, {:artifact_service_listen_failed, reason}}
      end
    else
      {:ok, %{listener: nil, disabled: true}}
    end
  end

  @impl true
  def handle_info(:accept, %{listener: nil} = state), do: {:noreply, state}

  def handle_info(:accept, %{listener: listener} = state) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _ = Task.start(fn -> handle_socket(socket) end)
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("artifact service accept failed: #{inspect(reason)}")
        Process.send_after(self(), :accept, 250)
        {:noreply, state}
    end
  end

  defp enabled?(opts) do
    case Keyword.get(opts, :enabled) do
      nil ->
        System.get_env("MN_ARTIFACT_ENABLED", "true")
        |> String.downcase()
        |> Kernel.in(["1", "true", "yes", "on"])

      value ->
        value in [true, "true", "1", "yes", "on"]
    end
  end

  defp port(opts) do
    Keyword.get(opts, :port) ||
      System.get_env("MN_ARTIFACT_PORT", to_string(@default_port))
      |> parse_port(@default_port)
  end

  defp bind_host(opts) do
    Keyword.get(opts, :bind_host) ||
      System.get_env("MN_ARTIFACT_BIND_HOST", "0.0.0.0")
  end

  defp bind_ip(host) do
    host = to_string(host)

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      _ -> {0, 0, 0, 0}
    end
  end

  defp handle_socket(socket) do
    with {:ok, raw} <- read_headers(socket, ""),
         {:ok, request} <- parse_request(raw),
         :ok <- authorize(request),
         :ok <- serve_request(socket, request) do
      :ok
    else
      {:error, {:http, status, message}} -> send_response(socket, status, [], message)
      {:error, reason} -> send_response(socket, 400, [], inspect(reason))
    end
  after
    :gen_tcp.close(socket)
  end

  defp read_headers(_socket, acc) when byte_size(acc) > @max_header_bytes,
    do: {:error, {:http, 431, "request headers too large"}}

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        next = acc <> data

        if String.contains?(next, "\r\n\r\n") do
          {:ok, next}
        else
          read_headers(socket, next)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_request(raw) do
    [head | _body] = String.split(raw, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head, "\r\n")

    with [method, path, _version] <- String.split(request_line, " ", parts: 3) do
      headers =
        header_lines
        |> Enum.map(&String.split(&1, ":", parts: 2))
        |> Enum.reduce(%{}, fn
          [key, value], acc -> Map.put(acc, String.downcase(String.trim(key)), String.trim(value))
          _other, acc -> acc
        end)

      {:ok, %{method: String.upcase(method), path: path, headers: headers}}
    else
      _ -> {:error, {:http, 400, "invalid request"}}
    end
  end

  defp authorize(%{headers: headers}) do
    token = Registry.auth_token()

    cond do
      not is_binary(token) or String.trim(token) == "" ->
        {:error, {:http, 503, "artifact auth token is not configured"}}

      Map.get(headers, "authorization") == "Bearer #{token}" ->
        :ok

      Map.get(headers, "x-mn-artifact-token") == token ->
        :ok

      true ->
        {:error, {:http, 401, "unauthorized"}}
    end
  end

  defp serve_request(socket, %{method: method, path: "/blobs/" <> sha256, headers: headers})
       when method in ["GET", "HEAD"] do
    sha256 = String.downcase(sha256)

    with true <- Regex.match?(@sha256_re, sha256),
         blob_path when is_binary(blob_path) <- BlobStore.path(sha256),
         true <- File.regular?(blob_path),
         true <- BlobStore.valid?(sha256),
         {:ok, stat} <- File.stat(blob_path),
         {:ok, range} <- parse_range(Map.get(headers, "range"), stat.size) do
      send_blob(socket, method, sha256, blob_path, stat.size, range)
    else
      false -> {:error, {:http, 404, "blob not found"}}
      nil -> {:error, {:http, 404, "blob not found"}}
      {:error, :invalid_range} -> {:error, {:http, 416, "invalid range"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp serve_request(_socket, %{method: method}) when method not in ["GET", "HEAD"],
    do: {:error, {:http, 405, "method not allowed"}}

  defp serve_request(_socket, _request), do: {:error, {:http, 404, "not found"}}

  defp parse_range(nil, size), do: {:ok, {0, max(size - 1, 0), :full}}
  defp parse_range("", size), do: {:ok, {0, max(size - 1, 0), :full}}

  defp parse_range("bytes=" <> spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix_text] ->
        with {suffix, ""} <- Integer.parse(suffix_text),
             true <- suffix > 0 do
          start = max(size - suffix, 0)
          {:ok, {start, max(size - 1, 0), :partial}}
        else
          _ -> {:error, :invalid_range}
        end

      [start_text, ""] ->
        with {start, ""} <- Integer.parse(start_text),
             true <- start >= 0 and start < size do
          {:ok, {start, size - 1, :partial}}
        else
          _ -> {:error, :invalid_range}
        end

      [start_text, end_text] ->
        with {start, ""} <- Integer.parse(start_text),
             {finish, ""} <- Integer.parse(end_text),
             true <- start >= 0 and finish >= start and start < size do
          {:ok, {start, min(finish, size - 1), :partial}}
        else
          _ -> {:error, :invalid_range}
        end

      _ ->
        {:error, :invalid_range}
    end
  end

  defp parse_range(_range, _size), do: {:error, :invalid_range}

  defp send_blob(socket, method, _sha256, path, size, {start, finish, kind}) do
    length = max(finish - start + 1, 0)

    headers = [
      {"accept-ranges", "bytes"},
      {"content-type", content_type(path)},
      {"content-length", Integer.to_string(length)}
    ]

    {status, headers} =
      if kind == :partial do
        {206, [{"content-range", "bytes #{start}-#{finish}/#{size}"} | headers]}
      else
        {200, headers}
      end

    :ok = send_headers(socket, status, headers)

    if method == "GET" and length > 0 do
      send_file_range(socket, path, start, length)
    else
      :ok
    end
  end

  defp send_file_range(socket, path, start, length) do
    with {:ok, file} <- File.open(path, [:read, :binary]),
         {:ok, _position} <- :file.position(file, start) do
      try do
        stream_file(socket, file, length)
      after
        File.close(file)
      end
    end
  end

  defp stream_file(_socket, _file, remaining) when remaining <= 0, do: :ok

  defp stream_file(socket, file, remaining) do
    chunk_size = min(@send_chunk_size, remaining)

    case IO.binread(file, chunk_size) do
      data when is_binary(data) ->
        :gen_tcp.send(socket, data)
        stream_file(socket, file, remaining - byte_size(data))

      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_response(socket, status, headers, body) do
    body = to_string(body)

    send_headers(socket, status, [{"content-length", byte_size(body)} | headers])
    :gen_tcp.send(socket, body)
  end

  defp send_headers(socket, status, headers) do
    reason = reason_phrase(status)

    lines =
      ["HTTP/1.1 #{status} #{reason}\r\n"] ++
        Enum.map(headers, fn {key, value} -> "#{key}: #{value}\r\n" end) ++
        ["connection: close\r\n\r\n"]

    :gen_tcp.send(socket, IO.iodata_to_binary(lines))
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(206), do: "Partial Content"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"
  defp reason_phrase(416), do: "Range Not Satisfiable"
  defp reason_phrase(431), do: "Request Header Fields Too Large"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(_), do: "Error"

  defp content_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".mp4" -> "video/mp4"
      ".mov" -> "video/quicktime"
      ".mkv" -> "video/x-matroska"
      ".webm" -> "video/webm"
      ".pdf" -> "application/pdf"
      ".json" -> "application/json"
      ".txt" -> "text/plain"
      _ -> "application/octet-stream"
    end
  end

  defp parse_port(value, default) do
    case Integer.parse(to_string(value)) do
      {port, ""} when port in 1..65_535 -> port
      _ -> default
    end
  end
end
