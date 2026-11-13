defmodule MirrorNeuron.Runtime.DeploymentController.RecordsTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.DeploymentController.Records

  test "long-lived deployments retain a bounded ordered history with their latest event" do
    events = Enum.map(1..100, &%{"version" => to_string(&1)})

    next =
      Records.append_deployment_event(%{"events" => events}, "promoted", %{"version" => "101"})

    assert length(next) == 100
    assert hd(next)["version"] == "2"
    assert List.last(next)["version"] == "101"
    assert List.last(next)["type"] == "promoted"
    assert List.last(next)["timestamp"]
  end
end
