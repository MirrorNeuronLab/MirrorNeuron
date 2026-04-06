defmodule MirrorNeuron.DistributedRegistry do
  use Horde.Registry

  def start_link(_init_arg) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique], name: __MODULE__)
  end

  @impl true
  def init(init_arg) do
    [members: :auto]
    |> Keyword.merge(init_arg)
    |> Horde.Registry.init()
  end
end
