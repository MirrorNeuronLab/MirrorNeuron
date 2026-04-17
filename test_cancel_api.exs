defmodule TestCancelApi do
  def run do
    # Create fake pending job
    job_id = "drug_discovery_loop-1776388976672-1c50c86dc919"
    MirrorNeuron.Persistence.RedisStore.persist_job(job_id, %{"status" => "pending", "job_id" => job_id})
    
    # Try calling force_cancel
    result = MirrorNeuron.cancel(job_id)
    IO.inspect(result, label: "Result")
  end
end
TestCancelApi.run()
