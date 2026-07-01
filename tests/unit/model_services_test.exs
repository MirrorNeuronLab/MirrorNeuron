defmodule MirrorNeuron.ModelServicesTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.ModelServices

  test "explicit model service JSON advertises model runner services" do
    env = %{
      "MN_MODEL_SERVICES_JSON" =>
        Jason.encode!(%{
          "services" => [
            %{
              "name" => "docker-model-runner",
              "tags" => ["model:gemma4:e2b", "model-id:gemma4:e2b"],
              "meta" => %{
                "model_id" => "gemma4:e2b",
                "model" => "ai/gemma4:E2B",
                "api_model" => "ai/gemma4:E2B"
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
    assert service["meta"]["model_id"] == "gemma4:e2b"
    assert "model:gemma4:e2b" in service["tags"]

    assert [%{"url" => "http://model-runner.docker.internal/engines/v1/models"}] =
             service["checks"]
  end

  test "symbolic model refs no longer expand inside core" do
    assert ModelServices.service_instances_for_models(["gemma4:e2b"], "node@lab") == []
  end

  test "runtime model preparation is rejected by core" do
    assert {:error, message} = ModelServices.prepare_runtime_model(%{"model" => "gemma4:e2b"})
    assert message =~ "mn-python-sdk"
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
