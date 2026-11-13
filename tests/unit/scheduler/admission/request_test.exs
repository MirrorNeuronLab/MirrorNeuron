defmodule MirrorNeuron.Scheduler.Admission.RequestTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.ResourceAllocation

  defp manifest do
    %{
      "policies" => %{
        "resource_allocation" => %{
          "mode" => "shared",
          "cpu_cores" => 2,
          "memory_mb" => 2048,
          "devices" => [%{"count" => 1, "sharing" => "shared", "reservation_memory_mb" => 4096}]
        }
      },
      "flow" => %{
        "nodes" =>
          Enum.map(["a", "b"], fn id ->
            %{
              "node_id" => id,
              "resources" => %{"cpu_cores" => 1, "memory_mb" => 1024, "gpu_count" => 1}
            }
          end)
      }
    }
  end

  test "one declared GPU covers multiple workers in the same run while CPU and RAM sum" do
    assert {:ok, request} = ResourceAllocation.request(manifest())
    assert request["cpu_cores"] == 2
    assert request["memory_mb"] == 2048
    assert [%{"count" => 1}] = request["devices"]

    for {key, value} <- [{"cpu_cores", 1}, {"memory_mb", 1024}] do
      undersized = put_in(manifest(), ["policies", "resource_allocation", key], value)
      assert {:error, :invalid_resource_allocation} = ResourceAllocation.request(undersized)
    end
  end

  test "an exclusive run derives its resource floor from the workers" do
    assert {:ok, request} = ResourceAllocation.request(Map.delete(manifest(), "policies"))
    assert request["mode"] == "exclusive_node"
    assert request["cpu_cores"] == 2
    assert request["memory_mb"] == 2048
  end

  for {key, value} <- [
        {"mode", "unknown"},
        {"cpu_cores", -1},
        {"cpu_cores", "2"},
        {"memory_mb", 0},
        {"devices", %{}},
        {"devices", [%{"count" => 65}]},
        {"devices", [%{"sharing" => "shared", "reservation_memory_mb" => 0}]}
      ] do
    test "rejects an invalid resource profile #{key}=#{inspect(value)}" do
      invalid =
        put_in(
          manifest(),
          ["policies", "resource_allocation", unquote(key)],
          unquote(Macro.escape(value))
        )

      assert {:error, :invalid_resource_allocation} = ResourceAllocation.request(invalid)
    end
  end

  test "shared model weights must fit the reservation and use unique identities" do
    for models <- [
          [%{"key" => "model", "memory_mb" => 4097}],
          [%{"key" => "model", "memory_mb" => 1024}, %{"key" => "model", "memory_mb" => 1024}]
        ] do
      invalid =
        put_in(
          manifest(),
          ["policies", "resource_allocation", "devices", Access.at(0), "models"],
          models
        )

      assert {:error, :invalid_resource_allocation} = ResourceAllocation.request(invalid)
    end
  end

  test "Compose GPU requests require a device allocation even without worker GPU resources" do
    input =
      manifest()
      |> put_in(["policies", "resource_allocation", "devices"], [])
      |> put_in(["flow", "nodes"], [%{"config" => %{"docker" => %{"gpus" => "all"}}}])

    assert {:error, :invalid_resource_allocation} = ResourceAllocation.request(input)
  end
end
