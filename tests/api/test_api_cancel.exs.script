defmodule TestApiCancel do
  use Plug.Test

  def run do
    # 1. Create a pending job
    job_id = "test_job_123"
    MirrorNeuron.Persistence.RedisStore.persist_job(job_id, %{"status" => "pending", "job_id" => job_id})

    # 2. Mock API request
    conn = conn(:post, "/api/v1/jobs/#{job_id}/cancel")
    conn = MirrorNeuron.API.Router.call(conn, MirrorNeuron.API.Router.init([]))

    IO.inspect(conn.status, label: "Status")
    IO.inspect(conn.resp_body, label: "Body")
  end
end
TestApiCancel.run()
