defmodule MirrorNeuron.Runtime.RedisEnvironmentTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runtime.RedisEnvironment

  @env_keys [
    "MN_REDIS_URL",
    "MN_CONTEXT_REDIS_URL",
    "MN_REDIS_HA_MODE",
    "MN_NETWORK_REDIS_HOST",
    "MN_NETWORK_REDIS_PORT"
  ]

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(@env_keys, &System.delete_env/1)
    System.put_env("MN_REDIS_HA_MODE", "single")

    :ok
  end

  test "agent env rewrites Redis URLs to the advertised network endpoint" do
    System.put_env("MN_REDIS_URL", "redis://:secret@redis:6379/0")
    System.put_env("MN_CONTEXT_REDIS_URL", "redis://:secret@redis:6379/1")
    System.put_env("MN_NETWORK_REDIS_HOST", "192.168.4.51")
    System.put_env("MN_NETWORK_REDIS_PORT", "56380")

    assert RedisEnvironment.agent_env() == %{
             "MN_REDIS_URL" => "redis://:secret@192.168.4.51:56380/0",
             "MN_CONTEXT_REDIS_URL" => "redis://:secret@192.168.4.51:56380/1"
           }
  end

  test "agent env derives context Redis URL from runtime Redis when unset" do
    System.put_env("MN_REDIS_URL", "redis://:secret@redis:6379/0")
    System.put_env("MN_NETWORK_REDIS_HOST", "192.168.4.51")
    System.put_env("MN_NETWORK_REDIS_PORT", "56380")

    assert RedisEnvironment.agent_env()["MN_CONTEXT_REDIS_URL"] ==
             "redis://:secret@192.168.4.51:56380/1"
  end

  test "rewrite leaves URLs unchanged without an advertised Redis endpoint" do
    assert RedisEnvironment.rewrite_for_advertised_endpoint("redis://:secret@redis:6379/0") ==
             "redis://:secret@redis:6379/0"
  end
end
