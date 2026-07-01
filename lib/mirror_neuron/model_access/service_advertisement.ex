defmodule MirrorNeuron.ModelAccess.ServiceAdvertisement do
  @moduledoc false

  alias MirrorNeuron.ModelServices

  def env_model_refs(env \\ System.get_env()), do: ModelServices.env_model_refs(env)

  def service_instances_for_models(model_refs, node_name, catalog \\ nil) do
    if catalog do
      ModelServices.service_instances_for_models(model_refs, node_name, catalog)
    else
      ModelServices.service_instances_for_models(model_refs, node_name)
    end
  end

  def service_instances_for_env(env, node_name, catalog \\ nil) do
    if catalog do
      ModelServices.service_instances_for_env(env, node_name, catalog)
    else
      ModelServices.service_instances_for_env(env, node_name)
    end
  end

  def advertise_env_models(node_name \\ Node.self(), env \\ System.get_env()),
    do: ModelServices.advertise_env_models(node_name, env)

  def advertise_models(model_refs, node_name \\ Node.self(), env \\ System.get_env()),
    do: ModelServices.advertise_models(model_refs, node_name, env)
end
