defmodule MirrorNeuron.Config do
  @moduledoc false

  def fetch!(key), do: Application.fetch_env!(:mirror_neuron, key)

  def string(_env_name, key), do: fetch!(key)

  def integer(_env_name, key), do: fetch!(key)

  def boolean(_env_name, key), do: fetch!(key)
end
