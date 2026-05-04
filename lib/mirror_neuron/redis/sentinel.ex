defmodule MirrorNeuron.Redis.Sentinel do
  @moduledoc false

  alias MirrorNeuron.Config

  @default_sentinel_port 26_379
  @sentinel_query_timeout_ms 5_000

  def enabled? do
    mode() == "sentinel"
  end

  def mode do
    "MN_REDIS_HA_MODE"
    |> Config.string(:redis_ha_mode)
    |> String.downcase()
  end

  def sentinels do
    "MN_REDIS_SENTINELS"
    |> Config.string(:redis_sentinels)
    |> parse_sentinels()
  end

  def master_name do
    Config.string("MN_REDIS_SENTINEL_MASTER", :redis_sentinel_master)
  end

  def db do
    Config.integer("MN_REDIS_DB", :redis_db)
  end

  def resolve_primary_url(query_fun \\ &query_sentinel/2) do
    sentinels()
    |> Enum.reduce_while({:error, :no_sentinels_available}, fn endpoint, last_error ->
      case query_fun.(endpoint, ["SENTINEL", "get-master-addr-by-name", master_name()]) do
        {:ok, [host, port]} when is_binary(host) ->
          {:halt, {:ok, primary_url(host, port)}}

        {:ok, other} ->
          {:cont, {:error, {:invalid_sentinel_reply, endpoint, other}}}

        {:error, reason} ->
          {:cont, {:error, {:sentinel_unavailable, endpoint, reason}}}

        other ->
          {:cont, {:error, {:invalid_sentinel_reply, endpoint, other || last_error}}}
      end
    end)
  end

  def parse_sentinels(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&parse_endpoint!/1)
  end

  def parse_sentinels(values) when is_list(values) do
    Enum.map(values, fn
      %{host: host, port: port} -> %{host: to_string(host), port: parse_port!(port)}
      {host, port} -> %{host: to_string(host), port: parse_port!(port)}
      value when is_binary(value) -> parse_endpoint!(value)
    end)
  end

  def primary_url(host, port) do
    build_url(
      redis_scheme(),
      mapped_host(host),
      parse_port!(port),
      db(),
      redis_username(),
      redis_password()
    )
  end

  def sentinel_url(%{host: host, port: port}) do
    build_url(
      "redis",
      host,
      parse_port!(port),
      nil,
      sentinel_username(),
      sentinel_password()
    )
  end

  def build_url(scheme, host, port, db, username \\ nil, password \\ nil) do
    %URI{
      scheme: scheme || "redis",
      userinfo: userinfo(username, password),
      host: host,
      port: parse_port!(port),
      path: path(db)
    }
    |> URI.to_string()
  end

  def query_sentinel(endpoint, command) do
    case Redix.start_link(sentinel_url(endpoint), sync_connect: true) do
      {:ok, conn} ->
        try do
          Redix.command(conn, command, timeout: @sentinel_query_timeout_ms)
        after
          GenServer.stop(conn, :normal, 1_000)
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:sentinel_query_exit, reason}}
  end

  defp parse_endpoint!(value) do
    value = String.trim(value)

    case String.split(value, ":", parts: 2) do
      [host, port] when host != "" ->
        %{host: host, port: parse_port!(port)}

      [host] when host != "" ->
        %{host: host, port: @default_sentinel_port}

      _ ->
        raise ArgumentError, "invalid Redis Sentinel endpoint #{inspect(value)}"
    end
  end

  defp parse_port!(port) when is_integer(port) and port in 1..65_535, do: port

  defp parse_port!(port) when is_binary(port) do
    case Integer.parse(port) do
      {integer, ""} when integer in 1..65_535 -> integer
      _ -> raise ArgumentError, "invalid Redis port #{inspect(port)}"
    end
  end

  defp parse_port!(port), do: raise(ArgumentError, "invalid Redis port #{inspect(port)}")

  defp path(nil), do: nil
  defp path(""), do: nil
  defp path(db), do: "/#{db}"

  defp redis_scheme do
    scheme =
      "MN_REDIS_URL"
      |> Config.string(:redis_url)
      |> URI.parse()
      |> Map.get(:scheme)

    case scheme do
      nil -> "redis"
      "" -> "redis"
      scheme -> scheme
    end
  end

  defp redis_username, do: optional_env("MN_REDIS_USERNAME", :redis_username)
  defp redis_password, do: optional_env("MN_REDIS_PASSWORD", :redis_password)

  defp sentinel_username,
    do: optional_env("MN_REDIS_SENTINEL_USERNAME", :redis_sentinel_username)

  defp sentinel_password,
    do: optional_env("MN_REDIS_SENTINEL_PASSWORD", :redis_sentinel_password)

  defp optional_env(env_name, key) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:mirror_neuron, key)
      "" -> nil
      value -> value
    end
  end

  defp mapped_host(host) do
    host_map()
    |> Map.get(host, host)
  end

  defp host_map do
    "MN_REDIS_SENTINEL_HOST_MAP"
    |> optional_env(:redis_sentinel_host_map)
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [from, to] when from != "" and to != "" -> Map.put(acc, from, to)
        _ -> acc
      end
    end)
  end

  defp userinfo(nil, nil), do: nil
  defp userinfo("", ""), do: nil
  defp userinfo("", nil), do: nil
  defp userinfo(nil, ""), do: nil

  defp userinfo(username, nil) when username not in [nil, ""] do
    URI.encode_www_form(username)
  end

  defp userinfo(nil, password) when password not in [nil, ""] do
    ":#{URI.encode_www_form(password)}"
  end

  defp userinfo("", password) when password not in [nil, ""] do
    ":#{URI.encode_www_form(password)}"
  end

  defp userinfo(username, password) do
    "#{URI.encode_www_form(username)}:#{URI.encode_www_form(password)}"
  end
end
