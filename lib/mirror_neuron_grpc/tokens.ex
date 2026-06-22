defmodule MirrorNeuron.Grpc.Tokens do
  @moduledoc false

  import Bitwise

  @auth_token "mirror_neuron_password"
  @admin_token "mirror_neuron_password_admin"

  def auth_token do
    @auth_token
  end

  def admin_token do
    @admin_token
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
