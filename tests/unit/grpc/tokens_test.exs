defmodule MirrorNeuron.Grpc.TokensTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.Tokens

  test "secure_compare accepts equal binaries only" do
    assert Tokens.secure_compare("secret", "secret")
    refute Tokens.secure_compare("secret", "different")
    refute Tokens.secure_compare("secret", "secret-with-extra")
    refute Tokens.secure_compare("secret", nil)
  end

  test "peer tokens are stable and scoped to one peer" do
    previous = System.get_env("MN_GRPC_AUTH_TOKEN")
    System.put_env("MN_GRPC_AUTH_TOKEN", "core-secret")

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_GRPC_AUTH_TOKEN", previous),
        else: System.delete_env("MN_GRPC_AUTH_TOKEN")
    end)

    token = Tokens.peer_token("mirror_neuron@peer-a")
    assert token != ""
    assert token == Tokens.peer_token("mirror_neuron@peer-a")
    refute token == Tokens.peer_token("mirror_neuron@peer-b")
    refute token == Tokens.auth_token()
  end
end
