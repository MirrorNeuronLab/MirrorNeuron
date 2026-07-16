defmodule MirrorNeuron.Runtime.DeliveryTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.Delivery

  test "removes transport attempts from durable workflow reports" do
    original =
      Message.new("job", "source", "worker", "work", %{"value" => 1},
        message_id: "semantic-message",
        headers: %{"mn.workflow.attempt" => 3}
      )
      |> put_in(["envelope", "attempt"], 2)

    stable = Delivery.stable_workflow_message(original)

    refute Map.has_key?(stable["envelope"], "attempt")
    assert stable["envelope"]["message_id"] == "semantic-message"
    assert stable["headers"]["mn.workflow.attempt"] == 3
    assert original["envelope"]["attempt"] == 2
  end
end
