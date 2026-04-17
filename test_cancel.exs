defmodule TestCancel do
  def run do
    result = MirrorNeuron.cancel("drug_discovery_loop-1776388976672-1c50c86dc919")
    IO.inspect(result, label: "Cancel Result")
  end
end
TestCancel.run()
