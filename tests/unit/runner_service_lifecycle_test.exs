defmodule MirrorNeuron.Runner.ServiceLifecycleTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runner.ServiceLifecycle

  test "fresh attempts have independent generations and repeated serving is not republished" do
    parent = self()
    callback = fn type, payload -> send(parent, {type, payload}) end
    first = ServiceLifecycle.new(%{}, agent_id: "listener", event_callback: callback)
    second = ServiceLifecycle.new(%{}, agent_id: "listener", event_callback: callback)
    refute first.receipt["generation"] == second.receipt["generation"]
    serving = ServiceLifecycle.publish(first, "serving", "")
    assert_receive {"service_lifecycle", %{"details" => %{"state" => "serving", "sequence" => 1}}}
    assert ServiceLifecycle.publish(serving, "serving", "") == serving
    refute_received {"service_lifecycle", _}
  end

  test "callback failures cannot become native project execution failures" do
    lifecycle =
      ServiceLifecycle.new(%{}, event_callback: fn _, _ -> raise "unavailable observer" end)

    assert ServiceLifecycle.publish(lifecycle, "starting", "").receipt["state"] == "starting"
  end
end
