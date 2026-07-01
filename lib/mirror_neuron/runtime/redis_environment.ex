defmodule MirrorNeuron.Runtime.RedisEnvironment do
  @moduledoc false

  alias MirrorNeuron.Config
  alias MirrorNeuron.Redis

  @redis_schemes ["redis", "rediss"]

  def agent_env do
    redis_url =
      Redis.connection_url()
      |> rewrite_for_advertised_endpoint()

    %{}
    |> put_nonempty("MN_REDIS_URL", redis_url)
    |> put_nonempty("MN_CONTEXT_REDIS_URL", context_redis_url(redis_url))
  rescue
    _ -> %{}
  end

  def rewrite_for_advertised_endpoint(url) when is_binary(url) do
    with {:ok, uri} <- redis_uri(url),
         host when is_binary(host) <- advertised_redis_host() do
      port = advertised_redis_port() || uri.port
      URI.to_string(%{uri | host: host, port: port})
    else
      _ -> url
    end
  end

  def rewrite_for_advertised_endpoint(url), do: url

  defp context_redis_url(redis_url) do
    case System.get_env("MN_CONTEXT_REDIS_URL") do
      value when is_binary(value) and value != "" ->
        rewrite_for_advertised_endpoint(value)

      _ ->
        redis_url
        |> redis_url_with_db("1")
        |> rewrite_for_advertised_endpoint()
    end
  end

  defp redis_url_with_db(url, db) when is_binary(url) do
    case redis_uri(url) do
      {:ok, uri} -> URI.to_string(%{uri | path: "/#{db}"})
      :error -> nil
    end
  end

  defp redis_url_with_db(_url, _db), do: nil

  defp redis_uri(url) do
    uri = URI.parse(url)

    if uri.scheme in @redis_schemes and is_binary(uri.host) do
      {:ok, uri}
    else
      :error
    end
  end

  defp advertised_redis_host do
    Config.optional_string("MN_NETWORK_REDIS_HOST", :network_redis_host)
  end

  defp advertised_redis_port do
    case Config.optional_string("MN_NETWORK_REDIS_PORT", :network_redis_port) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {port, ""} -> port
          _ -> nil
        end
    end
  end

  defp put_nonempty(map, _key, nil), do: map
  defp put_nonempty(map, _key, ""), do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)
end
