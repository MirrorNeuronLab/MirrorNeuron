defmodule TestListAgents do
  def run do
    result = MirrorNeuron.Persistence.RedisStore.list_agents("nonexistent-job")
    IO.inspect(result, label: "List Agents Result")
  end
end
TestListAgents.run()
