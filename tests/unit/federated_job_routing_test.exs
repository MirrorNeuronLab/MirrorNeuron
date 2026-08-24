defmodule MirrorNeuron.Cluster.FederatedJobRoutingTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Cluster.FederatedJobRouting

  test "keeps a locally owned job local" do
    owner =
      FederatedJobRouting.job_owner("job-local",
        local_lookup: fn "job-local" -> {:ok, %{}} end,
        projection_owner: fn _job_id -> flunk("local jobs must not use a projection") end,
        discover_owner: fn _job_id -> flunk("local jobs must not be discovered remotely") end
      )

    assert owner == nil
  end

  test "discovers a connected job owner when no projection has been synced yet" do
    assert FederatedJobRouting.job_owner("job-remote",
             local_lookup: fn "job-remote" -> {:error, :not_found} end,
             projection_owner: fn "job-remote" -> nil end,
             discover_owner: fn "job-remote" -> "mirror_neuron@spark" end
           ) == "mirror_neuron@spark"
  end

  test "discovers a run owner independently from its durable job definition" do
    assert FederatedJobRouting.run_owner("run-remote",
             local_lookup: fn "run-remote" -> {:error, :not_found} end,
             projection_owner: fn "run-remote" -> nil end,
             discover_owner: fn "run-remote" -> "mirror_neuron@spark" end
           ) == "mirror_neuron@spark"
  end
end
