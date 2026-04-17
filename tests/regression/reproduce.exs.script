defmodule Reproduce do
  def run do
    # 1. Create a pending job
    job_id = "drug_discovery_loop-1776388976672-1c50c86dc919"
    MirrorNeuron.Persistence.RedisStore.persist_job(job_id, %{"status" => "pending", "job_id" => job_id})
    
    # 2. Call cancel directly
    result = MirrorNeuron.cancel(job_id)
    IO.inspect(result, label: "Direct cancel result")
  end
end
Reproduce.run()
