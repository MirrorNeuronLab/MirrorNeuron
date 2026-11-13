defmodule MirrorNeuron.ResourceSpec.ValidationBoundaryTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.ResourceSpec

  test "rejects non-object entries in each rich resource collection" do
    for collection <- ["devices", "ports", "volumes"], value <- [nil, false, "bad", 42] do
      errors =
        ResourceSpec.validate_node(%{node_id: "worker", resources: %{collection => [value]}})

      assert "resources.#{collection}[0] for node worker must be an object" in errors
    end
  end

  test "rejects non-scalar comparison operators without crashing" do
    errors =
      ResourceSpec.validate_node(%{
        node_id: "worker",
        resources: %{
          "devices" => [%{"memory_operator" => %{}, "api_version_operator" => []}]
        }
      })

    assert length(errors) == 2
    assert Enum.all?(errors, &String.contains?(&1, "operator must be"))
  end

  test "deduplicates explicit device inventory while preserving explicit measurements" do
    devices =
      ResourceSpec.normalize_node_devices(%{
        "devices" => [%{"id" => "gpu-0", "memory_total_mb" => 32, "memory_used_mb" => 40}],
        "hardware" => %{"gpu" => [%{"id" => "gpu-0", "memory_total_mb" => 64}]}
      })

    assert [%{"id" => "gpu-0", "memory_total_mb" => 32, "memory_free_mb" => 0}] = devices
  end
end
