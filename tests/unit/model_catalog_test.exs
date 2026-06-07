defmodule MirrorNeuron.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ModelCatalog
  alias MirrorNeuron.ModelServices

  test "loads packaged catalog and resolves aliases" do
    catalog = ModelCatalog.load_catalog()

    assert {:ok, gemma} = ModelCatalog.resolve("gemme4:e2b", catalog)
    assert gemma["id"] == "gemma4:e2b"
    assert gemma["model"] == "ai/gemma4:E2B"

    assert {:ok, nemotron} = ModelCatalog.resolve("nemotron3-33b", catalog)
    assert nemotron["id"] == "ollama/nemotron3:33b"
    assert get_in(nemotron, ["requirements", "min_vram_gb"]) == 24
  end

  test "local catalog overrides merge into packaged entries" do
    path =
      Path.join(System.tmp_dir!(), "mn-model-catalog-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "models" => [
          %{
            "id" => "gemma4:e2b",
            "model" => "local/gemma4:E2B",
            "requirements" => %{"min_vram_gb" => 4}
          }
        ]
      })
    )

    on_exit(fn -> File.rm(path) end)

    catalog = ModelCatalog.load_catalog([path])
    assert {:ok, entry} = ModelCatalog.resolve("default", catalog)
    assert entry["model"] == "local/gemma4:E2B"
    assert get_in(entry, ["requirements", "min_vram_gb"]) == 4
    assert "gemme4:e2b" in entry["aliases"]
  end

  test "model services advertise provider and model tags without requiring every GPU alternative" do
    entry = ModelCatalog.resolve!("otterdesk-voice-llm:default")
    requirement = ModelCatalog.service_requirement(entry)
    instance = ModelCatalog.service_instance(entry, "gpu@lab")

    assert requirement["name"] == "docker-model-runner"
    assert "model:hf.co/nvidia/nvidia-nemotron-3-nano-30b-a3b-bf16" in requirement["tags"]
    assert "nvidia-h100" not in requirement["tags"]
    assert instance["node"] == "gpu@lab"
    assert instance["status"] == "passing"
  end

  test "node model env refs turn into service instances" do
    env = %{"MN_NODE_MODELS" => "gemma4:e2b, ollama/nemotron3:33b"}
    refs = ModelServices.env_model_refs(env)
    services = ModelServices.service_instances_for_models(refs, "node@lab")

    assert Enum.map(services, & &1["name"]) == ["docker-model-runner", "ollama"]
    assert Enum.all?(services, &(&1["node"] == "node@lab"))
  end

  test "model services use advertised host identity when docker hostname differs" do
    env = %{"MN_NETWORK_ADVERTISE_HOST" => "192.168.4.173"}

    assert ModelServices.advertised_node_name(:"mirror_neuron@mn-c13e508c", env) ==
             "mirror_neuron@192.168.4.173"
  end

  test "explicit model service node identity overrides advertised host" do
    env = %{
      "MN_MODEL_SERVICE_NODE_NAME" => "mirror_neuron@gpu-node",
      "MN_NETWORK_ADVERTISE_HOST" => "192.168.4.173"
    }

    assert ModelServices.advertised_node_name(:"mirror_neuron@mn-c13e508c", env) ==
             "mirror_neuron@gpu-node"
  end
end
