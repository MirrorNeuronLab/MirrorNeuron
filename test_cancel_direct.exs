defmodule TestCancelDirect do
  def run do
    job_id = "test_cancel_direct"
    # Create the job with exactly the fields that persist_initial_job creates
    job_map = %{
      "job_id" => job_id,
      "graph_id" => "graph-1",
      "job_name" => "Test Job",
      "long_lived" => false,
      "status" => "pending",
      "submitted_at" => "2026-04-16T12:00:00.000Z",
      "updated_at" => "2026-04-16T12:00:00.000Z",
      "root_agent_ids" => [],
      "placement_policy" => "local",
      "recovery_policy" => "local_restart",
      "result" => nil,
      "manifest_ref" => %{
        "graph_id" => "graph-1",
        "manifest_version" => "1.0",
        "manifest_path" => nil,
        "job_path" => nil
      }
    }
    MirrorNeuron.Persistence.RedisStore.persist_job(job_id, job_map)
    
    # Mock no runtime nodes
    System.put_env("MIRROR_NEURON_NODE_ROLE", "control")
    
    result = MirrorNeuron.cancel(job_id)
    IO.inspect(result, label: "Result")
  end
end
TestCancelDirect.run()
