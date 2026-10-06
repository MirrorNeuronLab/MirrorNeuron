defmodule MirrorNeuron.Runner.ContextEnvironmentTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.ContextEnvironment

  test "execution node owns its endpoint and credential as one binding" do
    submitted = %{
      "MN_CONTEXT_ADDR" => "submitter:50052",
      "MN_CONTEXT_AUTH_TOKEN" => "submitter-fixture",
      "MN_CONTEXT_TOKEN_COUNTER_FACTORY" => "submitter.counter",
      "OTHER" => "keep"
    }

    runtime = %{
      "MN_CONTEXT_ADDR" => "local:50052",
      "MN_CONTEXT_AUTH_TOKEN" => "selected-fixture",
      "MN_CONTEXT_OBSERVABILITY" => "true"
    }

    result = ContextEnvironment.bind(submitted, runtime)
    assert result["MN_CONTEXT_ADDR"] == "local:50052"
    assert result["MN_CONTEXT_AUTH_TOKEN"] == "selected-fixture"
    assert result["MN_CONTEXT_OBSERVABILITY"] == "true"
    refute Map.has_key?(result, "MN_CONTEXT_TOKEN_COUNTER_FACTORY")
    assert result["OTHER"] == "keep"
  end

  test "missing execution authentication fails before launching a worker" do
    assert_raise ArgumentError, ~r/execution node/, fn ->
      ContextEnvironment.bind(%{"MN_CONTEXT_AUTH_TOKEN" => "submitter-fixture"}, %{})
    end
  end

  test "workers without a context binding remain independent" do
    assert ContextEnvironment.bind(%{"OTHER" => "keep"}, %{}) == %{"OTHER" => "keep"}
  end
end
