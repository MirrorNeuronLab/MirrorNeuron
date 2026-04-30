defmodule MirrorNeuron.Redis.SentinelTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Redis
  alias MirrorNeuron.Redis.Sentinel

  @env_vars [
    "MIRROR_NEURON_REDIS_HA_MODE",
    "MIRROR_NEURON_REDIS_SENTINELS",
    "MIRROR_NEURON_REDIS_SENTINEL_MASTER",
    "MIRROR_NEURON_REDIS_SENTINEL_HOST_MAP",
    "MIRROR_NEURON_REDIS_DB",
    "MIRROR_NEURON_REDIS_URL",
    "MIRROR_NEURON_REDIS_USERNAME",
    "MIRROR_NEURON_REDIS_PASSWORD",
    "MIRROR_NEURON_REDIS_SENTINEL_USERNAME",
    "MIRROR_NEURON_REDIS_SENTINEL_PASSWORD",
    "MIRROR_NEURON_REDIS_WAIT_REPLICAS",
    "MIRROR_NEURON_REDIS_WAIT_TIMEOUT_MS",
    "MIRROR_NEURON_REDIS_RECONNECT_ATTEMPTS",
    "MIRROR_NEURON_REDIS_RECONNECT_BACKOFF_MS",
    "MIRROR_NEURON_REDIS_RECONNECT_MAX_BACKOFF_MS"
  ]

  setup do
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_app = Application.get_all_env(:mirror_neuron)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Application.put_all_env(mirror_neuron: saved_app)
    end)

    :ok
  end

  test "parses sentinel endpoints with default and explicit ports" do
    assert Sentinel.parse_sentinels("10.0.0.1,10.0.0.2:26380") == [
             %{host: "10.0.0.1", port: 26_379},
             %{host: "10.0.0.2", port: 26_380}
           ]
  end

  test "parses structured sentinel endpoints" do
    assert Sentinel.parse_sentinels([
             {"sentinel-a", 26_379},
             %{host: :sentinel_b, port: "26380"},
             "sentinel-c"
           ]) == [
             %{host: "sentinel-a", port: 26_379},
             %{host: "sentinel_b", port: 26_380},
             %{host: "sentinel-c", port: 26_379}
           ]
  end

  test "rejects malformed sentinel ports" do
    assert_raise ArgumentError, ~r/invalid Redis port/, fn ->
      Sentinel.parse_sentinels("10.0.0.1:not-a-port")
    end

    assert_raise ArgumentError, ~r/invalid Redis port/, fn ->
      Sentinel.parse_sentinels("10.0.0.1:70000")
    end
  end

  test "sentinel URL omits database selection and includes sentinel auth" do
    System.put_env("MIRROR_NEURON_REDIS_SENTINEL_USERNAME", "sentinel-user")
    System.put_env("MIRROR_NEURON_REDIS_SENTINEL_PASSWORD", "s p@ss")

    assert Sentinel.sentinel_url(%{host: "sentinel.local", port: 26_379}) ==
             "redis://sentinel-user:s+p%40ss@sentinel.local:26379"
  end

  test "resolves primary URL from first healthy sentinel" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "sentinel")
    System.put_env("MIRROR_NEURON_REDIS_SENTINELS", "sentinel-a:26379,sentinel-b:26380")
    System.put_env("MIRROR_NEURON_REDIS_SENTINEL_MASTER", "mirror-neuron")
    System.put_env("MIRROR_NEURON_REDIS_DB", "2")
    System.put_env("MIRROR_NEURON_REDIS_URL", "redis://localhost:6379/0")
    System.put_env("MIRROR_NEURON_REDIS_USERNAME", "worker")
    System.put_env("MIRROR_NEURON_REDIS_PASSWORD", "secret")
    System.put_env("MIRROR_NEURON_REDIS_SENTINEL_HOST_MAP", "redis-primary=10.0.0.9")

    query_fun = fn
      %{host: "sentinel-a"}, _command ->
        {:error, :down}

      %{host: "sentinel-b"}, ["SENTINEL", "get-master-addr-by-name", "mirror-neuron"] ->
        {:ok, ["redis-primary", "6379"]}
    end

    assert Sentinel.resolve_primary_url(query_fun) ==
             {:ok, "redis://worker:secret@10.0.0.9:6379/2"}
  end

  test "resolves primary with rediss scheme inherited from redis URL" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "sentinel")
    System.put_env("MIRROR_NEURON_REDIS_SENTINELS", "sentinel-a:26379")
    System.put_env("MIRROR_NEURON_REDIS_SENTINEL_MASTER", "mirror-neuron")
    System.put_env("MIRROR_NEURON_REDIS_DB", "5")
    System.put_env("MIRROR_NEURON_REDIS_URL", "rediss://localhost:6379/0")

    query_fun = fn %{host: "sentinel-a"}, _command -> {:ok, ["redis-primary", "6380"]} end

    assert Sentinel.resolve_primary_url(query_fun) == {:ok, "rediss://redis-primary:6380/5"}
  end

  test "returns last sentinel error when primary cannot be resolved" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "sentinel")
    System.put_env("MIRROR_NEURON_REDIS_SENTINELS", "sentinel-a:26379,sentinel-b:26380")
    System.put_env("MIRROR_NEURON_REDIS_SENTINEL_MASTER", "mirror-neuron")

    query_fun = fn
      %{host: "sentinel-a"}, _command -> {:error, :timeout}
      %{host: "sentinel-b"}, _command -> {:ok, ["missing-port"]}
    end

    assert {:error,
            {:invalid_sentinel_reply, %{host: "sentinel-b", port: 26_380}, ["missing-port"]}} =
             Sentinel.resolve_primary_url(query_fun)
  end

  test "redis connection URL uses sentinel resolver when HA mode is sentinel" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "sentinel")

    assert Redis.connection_url(fn -> {:ok, "redis://primary.example:6379/0"} end) ==
             "redis://primary.example:6379/0"
  end

  test "redis connection URL raises when sentinel primary cannot be resolved" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "sentinel")

    assert_raise RuntimeError, ~r/could not resolve Redis Sentinel primary/, fn ->
      Redis.connection_url(fn -> {:error, :no_primary} end)
    end
  end

  test "redis connection URL preserves single mode behavior" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "single")
    System.put_env("MIRROR_NEURON_REDIS_URL", "redis://single.example:6379/3")

    assert Redis.connection_url(fn -> raise "should not call sentinel" end) ==
             "redis://single.example:6379/3"
  end

  test "readonly redis errors are reconnectable" do
    assert Redis.reconnectable_error?(%Redix.Error{
             message: "READONLY You can't write against a read only replica."
           })
  end

  test "only reconnectable redis errors are retried" do
    assert Redis.reconnectable_error?(%Redix.ConnectionError{reason: :closed})
    assert Redis.reconnectable_error?({:redix_exit, :noproc})
    refute Redis.reconnectable_error?(%Redix.Error{message: "ERR wrong number of arguments"})
    refute Redis.reconnectable_error?(:other)
  end

  test "sentinel configuration validates" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "sentinel")
    System.put_env("MIRROR_NEURON_REDIS_SENTINELS", "127.0.0.1:26379")
    System.put_env("MIRROR_NEURON_REDIS_SENTINEL_MASTER", "mirror-neuron")
    System.put_env("MIRROR_NEURON_REDIS_DB", "0")
    System.put_env("MIRROR_NEURON_REDIS_WAIT_REPLICAS", "1")
    System.put_env("MIRROR_NEURON_REDIS_WAIT_TIMEOUT_MS", "100")

    assert :ok = MirrorNeuron.Config.validate!()
  end

  test "sentinel configuration rejects missing sentinel list" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "sentinel")
    System.put_env("MIRROR_NEURON_REDIS_SENTINELS", "")

    assert_raise ArgumentError, ~r/MIRROR_NEURON_REDIS_SENTINELS/, fn ->
      MirrorNeuron.Config.validate!()
    end
  end

  test "sentinel configuration rejects invalid mode and negative wait settings" do
    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "other")

    assert_raise ArgumentError, ~r/MIRROR_NEURON_REDIS_HA_MODE/, fn ->
      MirrorNeuron.Config.validate!()
    end

    System.put_env("MIRROR_NEURON_REDIS_HA_MODE", "sentinel")
    System.put_env("MIRROR_NEURON_REDIS_SENTINELS", "127.0.0.1:26379")
    System.put_env("MIRROR_NEURON_REDIS_SENTINEL_MASTER", "mirror-neuron")
    System.put_env("MIRROR_NEURON_REDIS_WAIT_REPLICAS", "-1")

    assert_raise ArgumentError, ~r/MIRROR_NEURON_REDIS_WAIT_REPLICAS/, fn ->
      MirrorNeuron.Config.validate!()
    end

    System.put_env("MIRROR_NEURON_REDIS_WAIT_REPLICAS", "0")
    System.put_env("MIRROR_NEURON_REDIS_RECONNECT_ATTEMPTS", "0")

    assert_raise ArgumentError, ~r/MIRROR_NEURON_REDIS_RECONNECT_ATTEMPTS/, fn ->
      MirrorNeuron.Config.validate!()
    end

    System.put_env("MIRROR_NEURON_REDIS_RECONNECT_ATTEMPTS", "10")
    System.put_env("MIRROR_NEURON_REDIS_DB", "-1")

    assert_raise ArgumentError, ~r/MIRROR_NEURON_REDIS_DB/, fn ->
      MirrorNeuron.Config.validate!()
    end
  end
end
