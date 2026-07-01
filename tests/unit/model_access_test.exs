defmodule MirrorNeuron.ModelAccessTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ModelAccess.Catalog
  alias MirrorNeuron.ModelAccess.ServiceAdvertisement

  test "catalog facade resolves model service tags" do
    entry = Catalog.resolve!("nemotron3")

    assert "model-id:nemotron3" in Catalog.service_tags(entry)
  end

  test "service advertisement facade creates docker model runner service instances" do
    [service] =
      ServiceAdvertisement.service_instances_for_models(["nemotron3"], "mirror_neuron@spark")

    assert service["name"] == "docker-model-runner"
    assert service["node"] == "mirror_neuron@spark"
    assert "model-id:nemotron3" in service["tags"]
  end
end
