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

  def secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and compare_bytes(left, right, 0) == 0
  end

  def secure_compare(_left, _right), do: false

  defp compare_bytes(<<>>, <<>>, acc), do: acc

  defp compare_bytes(<<left, left_rest::binary>>, <<right, right_rest::binary>>, acc) do
    compare_bytes(left_rest, right_rest, bor(acc, bxor(left, right)))
  end
end
