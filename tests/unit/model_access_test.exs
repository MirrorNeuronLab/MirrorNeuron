defmodule MirrorNeuron.ModelAccessTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ModelAccess.Catalog
  alias MirrorNeuron.ModelAccess.ServiceAdvertisement

  test "catalog facade reports SDK ownership" do
    assert Catalog.load() == %{}
    assert Catalog.list_entries() == []
    assert Catalog.resolve("nemotron3") == {:error, :model_catalog_owned_by_sdk}
    assert_raise ArgumentError, ~r/mn-python-sdk/, fn -> Catalog.resolve!("nemotron3") end
  end

  test "service advertisement facade reads explicit service instances" do
    env = %{
      "MN_MODEL_SERVICES_JSON" =>
        Jason.encode!(%{
          "services" => [
            %{
              "name" => "docker-model-runner",
              "tags" => ["model-id:nemotron3"],
              "meta" => %{"model_id" => "nemotron3", "model" => "nemotron3"}
            }
          ]
        })
    }

    [service] =
      ServiceAdvertisement.service_instances_for_env(env, "mirror_neuron@spark")

    assert service["name"] == "docker-model-runner"
    assert service["node"] == "mirror_neuron@spark"
    assert "model-id:nemotron3" in service["tags"]
  end
end
