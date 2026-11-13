defmodule MirrorNeuron.Builtins.Executor.RetryTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Builtins.Executor.Retry

  test "explicitly nonretryable errors override transient text" do
    refute Retry.retryable?(%{"error" => "connection reset", "retryable" => false})
    assert Retry.retryable?(%{"stderr" => "CONNECTION RESET"})
    refute Retry.retryable?(%{"error" => "invalid schema"})
  end

  test "nested error details are classified without string conversion crashes" do
    assert Retry.retryable?(%{"error" => %{"message" => "connection reset"}, "logs" => []})
    refute Retry.retryable?(%{"error" => %{"validation" => ["invalid input"]}})
  end
end
