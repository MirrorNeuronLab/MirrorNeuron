defmodule MirrorNeuron.Grpc.AuthTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.Auth

  defmodule Stream do
    defstruct [:adapter, :payload, :http_request_headers, :headers, :metadata, :request_headers]
  end

  defmodule Adapter do
    def get_headers(:payload), do: %{"authorization" => "Bearer secret-token"}
  end

  setup do
    previous = System.get_env("MN_GRPC_AUTH_TOKEN")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("MN_GRPC_AUTH_TOKEN")
        value -> System.put_env("MN_GRPC_AUTH_TOKEN", value)
      end
    end)

    :ok
  end

  test "authorizes bearer tokens from request headers" do
    stream = %Stream{headers: %{"authorization" => "Bearer secret-token"}}

    assert Auth.authorized?(stream, "secret-token")
  end

  test "authorizes tokens from grpc adapter request headers" do
    stream = %Stream{adapter: Adapter, payload: :payload}

    assert Auth.authorized?(stream, "secret-token")
  end

  test "authorizes tokens from grpc http request headers" do
    stream = %Stream{http_request_headers: %{"authorization" => "Bearer secret-token"}}

    assert Auth.authorized?(stream, "secret-token")
  end

  test "rejects missing, blank, and mismatched tokens" do
    refute Auth.authorized?(%Stream{headers: %{}}, "secret-token")

    refute Auth.authorized?(
             %Stream{headers: %{"authorization" => "Bearer wrong"}},
             "secret-token"
           )

    refute Auth.authorized?(%Stream{headers: %{"authorization" => "Bearer secret-token"}}, "")
  end

  test "authorizes the configured operator token" do
    System.put_env("MN_GRPC_AUTH_TOKEN", "configured-operator-token")
    stream = %Stream{headers: %{"authorization" => "Bearer configured-operator-token"}}

    assert :ok = Auth.authorize_operator!(stream)
  end
end
