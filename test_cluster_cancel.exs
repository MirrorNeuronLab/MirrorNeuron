defmodule TestClusterCancel do
  def run do
    # Start distributed Erlang
    Node.start(:"control@127.0.0.1")
    
    # Start a background runtime node
    System.cmd("elixir", ["--sname", "runtime", "-S", "mix", "run", "--no-halt"], env: [{"MIRROR_NEURON_NODE_ROLE", "runtime"}], background: true)
    
    Process.sleep(2000)
    
    Node.connect(:"runtime@127.0.0.1")
    IO.inspect(Node.list(), label: "Connected nodes")
    
    job_id = "test_cluster_cancel_job"
    MirrorNeuron.Persistence.RedisStore.persist_job(job_id, %{"status" => "pending", "job_id" => job_id})
    
    # We are a control node
    System.put_env("MIRROR_NEURON_NODE_ROLE", "control")
    
    result = MirrorNeuron.cancel(job_id)
    IO.inspect(result, label: "Control node cancel result")
    
    # Cleanup
    System.cmd("epmd", ["-kill"])
  end
end
TestClusterCancel.run()
