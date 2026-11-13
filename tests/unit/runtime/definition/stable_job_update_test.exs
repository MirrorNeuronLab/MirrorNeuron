defmodule MirrorNeuron.Runtime.StableJobUpdateTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.StableJobUpdate

  test "reactivation preserves the hire, data, terminal runs and paused schedules" do
    definition = %{
      "job_id" => "saved-job",
      "status" => "archived",
      "owner_node" => "original-owner",
      "data_generation" => 4,
      "run_ids" => ["completed-run"],
      "resolved_configuration" => %{"mode" => "saved"},
      "schedules" => [%{"status" => "paused"}],
      "bundle_ref" => "saved-bundle"
    }

    assert {:ok, restored} = StableJobUpdate.apply(definition, %{"status" => "active"})
    assert restored == Map.put(definition, "status", "active")
    assert {:ok, ^restored} = StableJobUpdate.apply(restored, %{"status" => "active"})
  end

  test "status updates cannot bypass archive or forge definition ownership" do
    definition = %{"job_id" => "saved-job", "status" => "active", "owner_node" => "owner"}

    for status <- ["archived", "running", "deleted", nil] do
      assert {:error, :invalid_job_update} =
               StableJobUpdate.apply(definition, %{"status" => status})
    end

    assert {:ok, ^definition} =
             StableJobUpdate.apply(definition, %{"owner_node" => "forged", "job_id" => "forged"})
  end
end
