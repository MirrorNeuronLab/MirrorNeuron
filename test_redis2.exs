defmodule TestRedis2 do
  def run do
    MirrorNeuron.Persistence.RedisStore.persist_job("test-job", %{"status" => "pending"})
    {:ok, job} = MirrorNeuron.Persistence.RedisStore.fetch_job("test-job")
    IO.inspect(job, label: "Job keys")
  end
end
TestRedis2.run()
