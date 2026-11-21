defmodule MirrorNeuron.ModelServices do
  @moduledoc "Model service advertisement and native SDK forwarding API."

  alias MirrorNeuron.ModelServices.Advertisement
  alias MirrorNeuron.ModelServices.Commands
  alias MirrorNeuron.ModelServices.Transport

  defdelegate env_model_refs(), to: Advertisement
  defdelegate env_model_refs(env), to: Advertisement
  defdelegate service_instances_for_models(model_refs, node_name), to: Advertisement
  defdelegate service_instances_for_models(model_refs, node_name, catalog), to: Advertisement
  defdelegate service_instances_for_env(env, node_name), to: Advertisement
  defdelegate service_instances_for_env(env, node_name, catalog), to: Advertisement
  defdelegate advertise_env_models(), to: Advertisement
  defdelegate advertise_env_models(node_name), to: Advertisement
  defdelegate advertise_env_models(node_name, env), to: Advertisement
  defdelegate advertise_models(model_refs), to: Advertisement
  defdelegate advertise_models(model_refs, node_name), to: Advertisement
  defdelegate advertise_models(model_refs, node_name, env), to: Advertisement
  defdelegate persist_node_runtime_model(model_ref), to: Advertisement
  defdelegate persist_node_runtime_model(model_ref, env), to: Advertisement
  defdelegate prepare_runtime_model_on_node(node_name, attrs), to: Commands
  defdelegate prepare_runtime_model_on_node(node_name, attrs, timeout), to: Commands
  defdelegate sync_litellm_gateway_on_node(node_name, attrs), to: Commands
  defdelegate sync_litellm_gateway_on_node(node_name, attrs, timeout), to: Commands
  defdelegate remove_litellm_gateway_route_on_node(node_name, attrs), to: Commands
  defdelegate remove_litellm_gateway_route_on_node(node_name, attrs, timeout), to: Commands
  defdelegate prepare_docker_worker_on_node(node_name, request), to: Commands
  defdelegate prepare_docker_worker_on_node(node_name, request, timeout), to: Commands
  defdelegate cleanup_docker_worker_on_node(node_name, request), to: Commands
  defdelegate cleanup_docker_worker_on_node(node_name, request, timeout), to: Commands
  defdelegate prepare_docker_compose_on_node(node_name, request), to: Commands
  defdelegate prepare_docker_compose_on_node(node_name, request, timeout), to: Commands
  defdelegate docker_compose_status_on_node(node_name, request), to: Commands
  defdelegate docker_compose_status_on_node(node_name, request, timeout), to: Commands
  defdelegate cleanup_docker_compose_on_node(node_name, request), to: Commands
  defdelegate cleanup_docker_compose_on_node(node_name, request, timeout), to: Commands
  defdelegate prepare_runtime_model(attrs), to: Commands
  defdelegate prepare_runtime_model(attrs, timeout), to: Commands
  defdelegate prepare_docker_worker(request), to: Commands
  defdelegate prepare_docker_worker(request, timeout), to: Commands
  defdelegate cleanup_docker_worker(request), to: Commands
  defdelegate cleanup_docker_worker(request, timeout), to: Commands
  defdelegate prepare_docker_compose(request), to: Commands
  defdelegate prepare_docker_compose(request, timeout), to: Commands
  defdelegate docker_compose_status(request), to: Commands
  defdelegate docker_compose_status(request, timeout), to: Commands
  defdelegate cleanup_docker_compose(request), to: Commands
  defdelegate cleanup_docker_compose(request, timeout), to: Commands
  defdelegate sync_litellm_gateway(attrs), to: Commands
  defdelegate sync_litellm_gateway(attrs, timeout), to: Commands
  defdelegate remove_litellm_gateway_route(attrs), to: Commands
  defdelegate remove_litellm_gateway_route(attrs, timeout), to: Commands
  defdelegate job_response_command(attrs), to: Commands
  defdelegate job_response_command(attrs, timeout), to: Commands
  defdelegate native_resource_command(attrs), to: Commands
  defdelegate native_resource_command(attrs, timeout), to: Commands
  defdelegate grpc_prepare_runtime_model(target, request, timeout), to: Transport
  defdelegate grpc_prepare_docker_worker(target, request, timeout), to: Transport
  defdelegate grpc_cleanup_docker_worker(target, request, timeout), to: Transport
  defdelegate grpc_prepare_docker_compose(target, request, timeout), to: Transport
  defdelegate grpc_docker_compose_status(target, request, timeout), to: Transport
  defdelegate grpc_cleanup_docker_compose(target, request, timeout), to: Transport
  defdelegate grpc_sync_litellm_gateway(target, request, timeout), to: Transport
  defdelegate grpc_remove_litellm_gateway_route(target, request, timeout), to: Transport
  defdelegate grpc_set_resource(target, request, timeout), to: Transport
  defdelegate advertised_node_name(), to: Advertisement
  defdelegate advertised_node_name(node_name), to: Advertisement
  defdelegate advertised_node_name(node_name, env), to: Advertisement
end
