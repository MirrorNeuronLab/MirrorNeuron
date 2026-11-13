defmodule MirrorNeuron.Runtime.RunRetry.ConfigurationTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.RunRetry.Configuration

  defp manifest do
    %{
      metadata: %{
        "run_retry" => %{
          "configuration_fields" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 5},
            "mode" => %{"type" => "string", "allowed_values" => ["safe", "strict"]}
          }
        }
      }
    }
  end

  test "retry controls accept declared bounds and reject coercion or undeclared settings" do
    for limit <- [1, 5] do
      assert :ok =
               Configuration.validate_overrides(manifest(), %{"limit" => limit, "mode" => "safe"})
    end

    for overrides <- [
          %{"limit" => 0},
          %{"limit" => 6},
          %{"limit" => "3"},
          %{"limit" => 3.0},
          %{"mode" => "other"},
          %{"undeclared" => true}
        ] do
      assert {:error, _} = Configuration.validate_overrides(manifest(), overrides)
    end
  end

  test "retry controls reject non-objects and oversized field sets" do
    assert :ok = Configuration.validate_overrides(manifest(), %{})

    for overrides <- [nil, [], "mode", Map.new(1..33, &{to_string(&1), 1})] do
      assert {:error, "Retry settings must be a bounded object."} =
               Configuration.validate_overrides(manifest(), overrides)
    end
  end
end
