defmodule MirrorNeuron.RPC do
  def call(node, module, function, args, timeout) do
    :rpc.call(node, module, function, args, timeout)
  end
end
