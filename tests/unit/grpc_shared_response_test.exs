defmodule MirrorNeuron.Grpc.SharedResponseTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Grpc.SharedResponse
  @type_name "mirrorneuron.cluster.v1.SetResourceResponse"

  @tag :tmp_dir
  test "inline boundary, encrypted large response, checksum, type and malformed reference", %{
    tmp_dir: dir
  } do
    inline = :binary.copy("x", 4_194_304)
    assert SharedResponse.encode(inline, @type_name, dir) == inline
    assert File.ls!(dir) == []
    data = inline <> "!"
    ref = SharedResponse.encode(data, @type_name, dir)
    assert <<0, "MNGR", 1, 4_194_305::64, digest::binary-size(32), _key::binary-size(32)>> = ref
    file = Path.join(dir, "grpc-response-v1-" <> Base.encode16(digest, case: :lower) <> ".bin")
    ciphertext = File.read!(file)
    assert :binary.match(ciphertext, :binary.copy("x", 1000)) == :nomatch
    assert SharedResponse.decode(ref, @type_name, dir) == data
    assert_raise GRPC.RPCError, ~r/integrity/, fn -> SharedResponse.decode(ref, "other", dir) end
    <<first, rest::binary>> = ciphertext
    File.write!(file, <<Bitwise.bxor(first, 1), rest::binary>>)

    assert_raise GRPC.RPCError, ~r/integrity/, fn ->
      SharedResponse.decode(ref, @type_name, dir)
    end

    assert_raise GRPC.RPCError, ~r/Invalid/, fn ->
      SharedResponse.decode(<<0, "MNGR", 1, "../path">>, @type_name, dir)
    end
  end
end
