defmodule TestRedis do
  def run do
    {:ok, job} = MirrorNeuron.Persistence.RedisStore.fetch_job("test-job") || {:ok, %{}}
    IO.inspect(job, label: "Job keys")
  end
end
TestRedis.run()
