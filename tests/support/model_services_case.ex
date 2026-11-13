defmodule MirrorNeuron.ModelServicesCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.ModelServicesCase
    end
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  def restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
