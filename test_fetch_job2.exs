defmodule TestFetchJob2 do
  def run do
    # Just insert it directly into redis
    job_id = "drug_discovery_loop-1776388976672-1c50c86dc919"
    MirrorNeuron.Persistence.RedisStore.persist_job(job_id, %{"status" => "pending", "job_id" => job_id})
    
    result = MirrorNeuron.cancel(job_id)
    IO.inspect(result, label: "Cancel Result")
  end
end
TestFetchJob2.run()
