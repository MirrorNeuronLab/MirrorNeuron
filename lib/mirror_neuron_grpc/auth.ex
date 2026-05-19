defmodule MirrorNeuron.Grpc.Auth do
  @moduledoc false

  import Bitwise

  @auth_token_env "MN_GRPC_AUTH_TOKEN"
  @token_headers ["authorization"]

  def authorize_operator!(stream) do
    case operator_token() do
      {:ok, expected_token} ->
        if authorized?(stream, expected_token) do
          :ok
        else
          raise GRPC.RPCError,
            status: GRPC.Status.unauthenticated(),
            message: "gRPC auth token is required for this RPC"
        end

      :error ->
        raise GRPC.RPCError,
          status: GRPC.Status.unauthenticated(),
          message: "#{@auth_token_env} must be set before protected gRPC RPCs can be used"
    end
  end

  def authorized?(stream, expected_token) when is_binary(expected_token) do
    expected_token = String.trim(expected_token)

    expected_token != "" and
      stream
      |> metadata()
      |> token_candidates()
      |> Enum.any?(&secure_compare(&1, expected_token))
  end

  def authorized?(_stream, _expected_token), do: false

  defp operator_token do
    case System.get_env(@auth_token_env, "") |> String.trim() do
      "" -> :error
      token -> {:ok, token}
    end
  end

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

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and compare_bytes(left, right) == 0
  end

  defp secure_compare(_left, _right), do: false

  defp compare_bytes(left, right), do: compare_bytes(left, right, 0)
  defp compare_bytes(<<>>, <<>>, acc), do: acc

  defp compare_bytes(<<left, left_rest::binary>>, <<right, right_rest::binary>>, acc) do
    compare_bytes(left_rest, right_rest, bor(acc, bxor(left, right)))
  end
end
