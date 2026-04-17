defmodule TestNoRuntime do
  def run do
    job_id = "test-job-no-runtime"
    MirrorNeuron.Persistence.RedisStore.persist_job(job_id, %{"status" => "pending", "job_id" => job_id})
    
    # Mock call_control_or_runtime by setting node_role to control, and having no runtime nodes
    System.put_env("MIRROR_NEURON_NODE_ROLE", "control")
    
    result = MirrorNeuron.cancel(job_id)
    IO.inspect(result, label: "Cancel without runtime")
  end
end
TestNoRuntime.run()
