defmodule MirrorNeuron.Grpc.TokensTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Grpc.Tokens

  test "secure_compare accepts equal binaries only" do
    assert Tokens.secure_compare("secret", "secret")
    refute Tokens.secure_compare("secret", "different")
    refute Tokens.secure_compare("secret", "secret-with-extra")
    refute Tokens.secure_compare("secret", nil)
  end
end
