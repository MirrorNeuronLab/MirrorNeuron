defmodule MirrorNeuron.Scheduler.RecoveryPlanTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Scheduler.RecoveryPlan

  test "final validation rejects missing, failed and no-longer-visible targets" do
    opts = [validation_nodes: [%{"name" => "healthy", "status" => "healthy"}]]

    for target <- [nil, "failed", "missing"] do
      plan = %{"placements" => [%{"node" => target}]}
      assert {:placement_blocked, _} = RecoveryPlan.validate_recovery_plan(plan, "failed", opts)
    end

    assert {:placement_blocked, _} = RecoveryPlan.validate_recovery_plan(%{}, "failed", opts)
  end

  test "a healthy node made scheduling-ineligible cannot receive recovery" do
    plan = %{"placements" => [%{"node" => "owner"}]}

    assert {:placement_blocked, reason} =
             RecoveryPlan.validate_recovery_plan(plan, "failed",
               validation_nodes: [%{name: "owner", status: "healthy", scheduling_eligible: false}]
             )

    assert reason =~ "scheduling-ineligible"
  end

  test "healthy eligible target survives final validation" do
    plan = %{"placements" => [%{"node" => "owner"}]}

    assert :ok =
             RecoveryPlan.validate_recovery_plan(plan, "failed",
               validation_nodes: [%{name: "owner", status: "healthy", scheduling_eligible: true}]
             )
  end
end
