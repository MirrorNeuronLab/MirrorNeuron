defmodule MirrorNeuron.Grpc.Tokens do
  @moduledoc false

  @auth_token_env "MN_GRPC_AUTH_TOKEN"
  @auth_token_file_env "MN_GRPC_AUTH_TOKEN_FILE"
  @admin_token_env "MN_GRPC_ADMIN_TOKEN"
  @admin_token_file_env "MN_GRPC_ADMIN_TOKEN_FILE"
  @legacy_admin_token_env "MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN"

  def auth_token do
    resolve_token(@auth_token_file_env, [@auth_token_env])
  end

  def admin_token do
    resolve_token(@admin_token_file_env, [@admin_token_env, @legacy_admin_token_env])
  end

  defp resolve_token(file_env, env_names) do
    read_token_file(System.get_env(file_env)) ||
      Enum.find_value(env_names, fn name ->
        name
        |> System.get_env()
        |> normalize_token()
      end)
  end

  defp read_token_file(path) do
    path = normalize_token(path)

    if path do
      path
      |> File.read()
      |> case do
        {:ok, token} -> normalize_token(token)
        {:error, _reason} -> nil
      end
    end
  end

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      token -> token
    end
  end

  defp normalize_token(_value), do: nil
end
