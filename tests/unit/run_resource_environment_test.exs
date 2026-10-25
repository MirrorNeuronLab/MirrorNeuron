defmodule MirrorNeuron.Runtime.RunResourceEnvironmentTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.RunResourceEnvironment

  test "maps host GPU selections into a restricted container's local ordinal space" do
    config = %{
      "resource_allocation" => %{
        "mode" => "shared",
        "devices" => [
          %{"id" => "GPU-a", "driver" => "cuda", "index" => 2},
          %{"id" => "GPU-b", "driver" => "cuda", "index" => 4}
        ]
      }
    }

    env = %{"MN_ALLOCATED_DEVICE_IDS" => "GPU-b", "CUDA_VISIBLE_DEVICES" => "4"}
    assert RunResourceEnvironment.for_container(config, env)["CUDA_VISIBLE_DEVICES"] == "1"
    assert RunResourceEnvironment.for_container(config, %{})["CUDA_VISIBLE_DEVICES"] == "0,1"
    assert RunResourceEnvironment.for_container(%{}, env) == env
  end
end
