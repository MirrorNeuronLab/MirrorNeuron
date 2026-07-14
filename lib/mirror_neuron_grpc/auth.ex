defmodule MirrorNeuron.Grpc.Auth do
  @moduledoc false

  @token_headers ["authorization"]

  def authorize_identity!(stream) do
    expected_token = MirrorNeuron.Grpc.Tokens.auth_token()

    if authorized?(stream, expected_token) do
      :ok
    else
      raise GRPC.RPCError,
        status: GRPC.Status.unauthenticated(),
        message: "gRPC client identity is required for this RPC"
    end
  end

  def authorized?(stream, expected_token) when is_binary(expected_token) do
    expected_token = String.trim(expected_token)

    expected_token != "" and
      stream
      |> metadata()
      |> token_candidates()
      |> Enum.any?(&MirrorNeuron.Grpc.Tokens.secure_compare(&1, expected_token))
  end

  def authorized?(_stream, _expected_token), do: false

  defp metadata(stream) when is_map(stream) do
    stream_map = if Map.has_key?(stream, :__struct__), do: Map.from_struct(stream), else: stream

    headers =
      stream_map
      |> adapter_headers()
      |> Kernel.++(
        [:http_request_headers, :headers, :metadata, :request_headers]
        |> Enum.flat_map(&metadata_values(Map.get(stream_map, &1)))
      )

    Enum.reduce(headers, %{}, fn {key, value}, acc -> Map.put(acc, normalize_key(key), value) end)
  end

  defp metadata(_stream), do: %{}

  defp adapter_headers(%{adapter: adapter, payload: payload}) when is_atom(adapter) do
    if match?({:module, ^adapter}, Code.ensure_loaded(adapter)) and
         function_exported?(adapter, :get_headers, 1) do
      adapter.get_headers(payload) |> metadata_values()
    else
      []
    end
  end

  defp adapter_headers(_stream_map), do: []

  defp metadata_values(nil), do: []
  defp metadata_values(metadata) when is_map(metadata), do: Map.to_list(metadata)
  defp metadata_values(metadata) when is_list(metadata), do: metadata
  defp metadata_values(_metadata), do: []

  defp token_candidates(metadata) do
    @token_headers
    |> Enum.flat_map(fn header -> metadata |> Map.get(header) |> header_values() end)
    |> Enum.flat_map(&authorization_values/1)
  end

  defp header_values(nil), do: []
  defp header_values(values) when is_list(values), do: values
  defp header_values(value), do: [value]

  defp authorization_values(value) when is_binary(value) do
    value = String.trim(value)

    case String.split(value, " ", parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer", do: [String.trim(token)], else: [value]

      _ ->
        [value]
    end
  end

  defp authorization_values(_value), do: []

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(key), do: key |> to_string() |> String.downcase()
end
