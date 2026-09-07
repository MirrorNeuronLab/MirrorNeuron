defmodule MirrorNeuron.ContextEnginePreflightTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.ContextEnginePreflight

  setup do
    keys = ["MN_CONTEXT_ADDR", "CONTEXT_ENGINE_ADDR", "CONTEXT_ENGINE_READY_TIMEOUT_MS"]
    previous = Enum.map(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)
    :ok
  end

  test "uses the worker context address instead of host-local defaults or the legacy address" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    System.put_env("MN_CONTEXT_ADDR", " 127.0.0.1:#{port} ")
    System.put_env("CONTEXT_ENGINE_ADDR", "127.0.0.1:1")

    assert :ok = ContextEnginePreflight.ensure_available(true)
    assert {:ok, socket} = :gen_tcp.accept(listener, 100)
    :gen_tcp.close(socket)
  end

  test "does not mask an unavailable configured context engine with a reachable legacy address" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    System.put_env("MN_CONTEXT_ADDR", "127.0.0.1:1")
    System.put_env("CONTEXT_ENGINE_ADDR", "127.0.0.1:#{port}")

    assert {:error, reason} = ContextEnginePreflight.ensure_available(true)
    assert reason =~ "MN_CONTEXT_ADDR"
    assert reason =~ "127.0.0.1:1:"
  end

  test "accepts the legacy address when the canonical address is blank" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    System.put_env("MN_CONTEXT_ADDR", " ")
    System.put_env("CONTEXT_ENGINE_ADDR", "127.0.0.1:#{port}")

    assert :ok = ContextEnginePreflight.ensure_available(true)
  end

  test "skips the check when context engine is not required" do
    assert :ok = ContextEnginePreflight.ensure_available(false)
  end

  test "returns an actionable error when required context engine is unreachable" do
    previous_addr = System.get_env("CONTEXT_ENGINE_ADDR")
    previous_timeout = System.get_env("CONTEXT_ENGINE_READY_TIMEOUT_MS")

    System.put_env("CONTEXT_ENGINE_ADDR", "127.0.0.1:1")
    System.put_env("CONTEXT_ENGINE_READY_TIMEOUT_MS", "25")

    try do
      assert {:error, reason} = ContextEnginePreflight.ensure_available(true)
      assert reason =~ "required_context_engine=true"
      assert reason =~ "CONTEXT_ENGINE_ADDR"
      assert reason =~ "127.0.0.1:1"
    after
      restore_env("CONTEXT_ENGINE_ADDR", previous_addr)
      restore_env("CONTEXT_ENGINE_READY_TIMEOUT_MS", previous_timeout)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
