defmodule MirrorNeuron.CLI.Commands.Server do
  alias MirrorNeuron.CLI.Output
  alias MirrorNeuron.CLI.UI

  def run do
    Output.maybe_print_banner(:server, "Runtime node #{Node.self()}")
    UI.puts(UI.server_ready(to_string(Node.self())))

    receive do
    end
  end
end
