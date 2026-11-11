defmodule MirrorNeuron.Grpc.RuntimeControlAuthTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Grpc.{Auth, Tokens}

  setup do
    keys = ~w(MN_RUNTIME_CONTROL_TOKEN MN_GRPC_AUTH_TOKEN MN_API_TOKEN)
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env(%{
      "MN_RUNTIME_CONTROL_TOKEN" => "runtime-secret",
      "MN_GRPC_AUTH_TOKEN" => "internal-secret",
      "MN_API_TOKEN" => "surface-secret"
    })

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    :ok
  end

  test "the public native gateway requires its distinct control credential" do
    assert :ok =
             Auth.authorize_runtime!(%{headers: %{"authorization" => "Bearer runtime-secret"}})

    for token <- ["", "surface-secret", "internal-secret", Tokens.peer_token("peer@test")] do
      error =
        assert_raise GRPC.RPCError, fn ->
          Auth.authorize_runtime!(%{headers: %{"authorization" => "Bearer " <> token}})
        end

      assert error.status == GRPC.Status.unauthenticated()
    end
  end

  test "an unset control credential never grants anonymous access" do
    System.delete_env("MN_RUNTIME_CONTROL_TOKEN")
    assert_raise GRPC.RPCError, fn -> Auth.authorize_runtime!(%{headers: %{}}) end
  end
end
