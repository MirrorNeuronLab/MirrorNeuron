defmodule TestListJobs do
  def run do
    {:ok, jobs} = MirrorNeuron.Persistence.RedisStore.list_jobs()
    IO.inspect(jobs, label: "Jobs in Redis")
    
    {:ok, job_ids} = MirrorNeuron.Persistence.RedisStore.list_job_ids()
    IO.inspect(job_ids, label: "Job IDs in Redis")
  end
end
TestListJobs.run()
