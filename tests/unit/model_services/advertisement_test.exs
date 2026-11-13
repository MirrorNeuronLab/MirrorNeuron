defmodule MirrorNeuron.ModelServicesTest.AdvertisementTest do
  use MirrorNeuron.ModelServicesCase, async: false

  alias MirrorNeuron.ModelServices

  test "explicit model service JSON advertises model runner services" do
    env = %{
      "MN_MODEL_SERVICES_JSON" =>
        Jason.encode!(%{
          "services" => [
            %{
              "name" => "docker-model-runner",
              "tags" => [
                "model:nemotron-3.5-bolt-e4b:q4_k_m",
                "model-id:nemotron-3.5-bolt-e4b:q4_k_m"
              ],
              "meta" => %{
                "model_id" => "nemotron-3.5-bolt-e4b:q4_k_m",
                "model" => "nemotron-3.5-bolt-e4b:q4_k_m",
                "api_model" => "nemotron-3.5-bolt-e4b:q4_k_m"
              }
            }
          ]
        }),
      "MN_DOCKER_MODEL_RUNNER_API_BASE" => "http://model-runner.docker.internal/engines/v1"
    }

    [service] = ModelServices.service_instances_for_env(env, "node@lab")

    assert service["name"] == "docker-model-runner"
    assert service["node"] == "node@lab"
    assert service["status"] == "passing"
    assert service["meta"]["model_id"] == "nemotron-3.5-bolt-e4b:q4_k_m"
    assert "model:nemotron-3.5-bolt-e4b:q4_k_m" in service["tags"]

    assert [%{"url" => "http://model-runner.docker.internal/engines/v1/models"}] =
             service["checks"]
  end

  test "symbolic model refs no longer expand inside core" do
    assert ModelServices.service_instances_for_models(
             ["nemotron-3.5-bolt-e4b:q4_k_m"],
             "node@lab"
           ) == []
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
