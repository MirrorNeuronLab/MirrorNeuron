defmodule MirrorNeuron.Cluster.NodeAdapter do
  @moduledoc false

  def self, do: adapter().self()
  def list, do: adapter().list()
  def connect(node), do: adapter().connect(node)
  def disconnect(node), do: adapter().disconnect(node)
  def set_cookie(node, cookie), do: adapter().set_cookie(node, cookie)

  def rpc_call(node, module, function, args, timeout) do
    adapter().rpc_call(node, module, function, args, timeout)
  end

  defp adapter do
    Application.get_env(:mirror_neuron, :cluster_node_adapter, __MODULE__.Beam)
  end
end

defmodule MirrorNeuron.Cluster.NodeAdapter.Beam do
  @moduledoc false

  def self, do: Node.self()
  def list, do: Node.list()
  def connect(node), do: Node.connect(node)
  def disconnect(node), do: Node.disconnect(node)
  def set_cookie(node, cookie), do: Node.set_cookie(node, cookie)

  def rpc_call(node, module, function, args, timeout) do
    :rpc.call(node, module, function, args, timeout)
  end
end
