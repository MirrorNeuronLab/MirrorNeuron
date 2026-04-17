defmodule TestCancelRuntime do
  def run do
    job_id = "test_cancel_runtime"
    MirrorNeuron.Persistence.RedisStore.persist_job(job_id, %{"status" => "pending", "job_id" => job_id})
    
    # Mock runtime node
    System.put_env("MIRROR_NEURON_NODE_ROLE", "runtime")
    
    result = MirrorNeuron.cancel(job_id)
    IO.inspect(result, label: "Result")
  end
end
TestCancelRuntime.run()
