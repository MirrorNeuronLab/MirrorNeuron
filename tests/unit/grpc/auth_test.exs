defmodule MirrorNeuron.Grpc.AuthTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Grpc.Auth

  @auth_token_env "MN_GRPC_AUTH_TOKEN"
  @auth_token_file_env "MN_GRPC_AUTH_TOKEN_FILE"

  defmodule Stream do
    defstruct [:adapter, :payload, :http_request_headers, :headers, :metadata, :request_headers]
  end

  defmodule Adapter do
    def get_headers(:payload), do: %{"authorization" => "Bearer secret-token"}
  end

  setup do
    old_token = System.get_env(@auth_token_env)
    old_token_file = System.get_env(@auth_token_file_env)

    System.delete_env(@auth_token_env)
    System.delete_env(@auth_token_file_env)

    on_exit(fn ->
      restore_env(@auth_token_env, old_token)
      restore_env(@auth_token_file_env, old_token_file)
    end)
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

  test "authorizes operator token from token file before stale env token" do
    token_file =
      Path.join(System.tmp_dir!(), "mn-auth-token-#{System.unique_integer([:positive])}")

    File.write!(token_file, "file-token\n")
    on_exit(fn -> File.rm(token_file) end)

    System.put_env(@auth_token_env, "stale-env-token")
    System.put_env(@auth_token_file_env, token_file)

    stream = %Stream{headers: %{"authorization" => "Bearer file-token"}}

    assert :ok = Auth.authorize_operator!(stream)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
