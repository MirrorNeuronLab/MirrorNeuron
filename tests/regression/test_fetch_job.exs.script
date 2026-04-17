defmodule TestFetchJob do
  def run do
    # Create the job exactly as it would be created
    job_id = "test-job-1"
    manifest = %{graph_id: "graph-1", job_name: "Test Job", long_lived: false, entrypoints: [], policies: %{}, manifest_version: "1.0"}
    MirrorNeuron.Runtime.start_job(manifest, job_id: job_id)
    
    # Wait a sec
    Process.sleep(100)
    
    case MirrorNeuron.Persistence.RedisStore.fetch_job(job_id) do
      {:ok, job} -> 
        IO.inspect(job, label: "Fetched Job")
        IO.inspect(job["status"], label: "Status")
        IO.puts("Status in list? #{job["status"] in ["pending", "running", "paused"]}")
      other -> 
        IO.inspect(other, label: "Other")
    end
  end
end
TestFetchJob.run()
