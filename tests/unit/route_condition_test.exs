defmodule MirrorNeuron.Runtime.RouteConditionTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.RouteCondition

  test "evaluates structured and expression conditions without arbitrary code" do
    message =
      Message.new(
        "job-1",
        "router",
        "sink",
        "classified_request",
        %{"domain" => "finance", "confidence" => 0.92},
        headers: %{"tenant" => "regulated"}
      )

    context = RouteCondition.context(message, %{"priority" => "high"}, %{count: 2})

    assert RouteCondition.matches?(%{"expr" => "${payload.priority} == \"high\""}, context)
    assert RouteCondition.matches?(%{"expr" => "${message.body.confidence} >= 0.9"}, context)

    assert RouteCondition.matches?(
             %{"path" => "message.headers.tenant", "op" => "==", "value" => "regulated"},
             context
           )

    assert RouteCondition.matches?(%{"path" => "state.count", "op" => ">", "value" => 1}, context)
    refute RouteCondition.matches?(%{"expr" => "${message.body.domain} == \"support\""}, context)
  end

  test "validates supported condition shapes" do
    assert :ok = RouteCondition.validate(%{"expr" => "${state.confidence} >= 0.7"})

    assert :ok =
             RouteCondition.validate(%{
               "all" => [%{"path" => "payload.domain", "value" => "finance"}]
             })

    assert {:error, reason} = RouteCondition.validate(%{"expr" => "System.halt()"})
    assert reason =~ "unsupported route condition expression"
  end
end
