defmodule MirrorNeuron.Grpc.Tokens do
  @moduledoc false

  import Bitwise

  def auth_token do
    MirrorNeuron.Config.secret(
      "MN_GRPC_AUTH_TOKEN",
      :grpc_auth_token,
      "MN_GRPC_AUTH_TOKEN_FILE",
      :grpc_auth_token_file
    )
  end

  def peer_token(peer_name) when is_binary(peer_name) do
    peer_name = String.trim(peer_name)
    secret = auth_token() |> to_string() |> String.trim()

    if peer_name == "" or secret == "" do
      ""
    else
      :crypto.mac(:hmac, :sha256, secret, "mirror-neuron:federation:v1:#{peer_name}")
      |> Base.url_encode64(padding: false)
    end
  end

  def peer_token(_peer_name), do: ""

  def secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and compare_bytes(left, right, 0) == 0
  end

  def secure_compare(_left, _right), do: false

  defp compare_bytes(<<>>, <<>>, acc), do: acc

  defp compare_bytes(<<left, left_rest::binary>>, <<right, right_rest::binary>>, acc) do
    compare_bytes(left_rest, right_rest, bor(acc, bxor(left, right)))
  end
end
