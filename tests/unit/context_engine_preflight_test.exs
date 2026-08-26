defmodule MirrorNeuron.ContextEnginePreflightTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.ContextEnginePreflight

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
