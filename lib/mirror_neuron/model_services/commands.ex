defmodule MirrorNeuron.ModelServices.Commands do
  @moduledoc "Routes native resource commands to the local owning SDK with typed requests."

  alias Mirrorneuron.Cluster.V1.CleanupDockerComposeRequest
  alias Mirrorneuron.Cluster.V1.CleanupDockerWorkerRequest
  alias Mirrorneuron.Cluster.V1.DockerComposeStatusRequest
  alias MirrorNeuron.ModelServices.Models
  alias Mirrorneuron.Cluster.V1.PrepareDockerComposeRequest
  alias Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest
  alias MirrorNeuron.ModelServices.Requests
  alias MirrorNeuron.ModelServices.Transport

  @doc false
  def prepare_runtime_model_on_node(node_name, attrs, timeout \\ 1_200_000) when is_map(attrs) do
    native_command_on_node(
      node_name,
      attrs,
      timeout,
      &prepare_runtime_model/2,
      "runtime model prepare request",
      "PrepareRuntimeModel gRPC"
    )
  end

  @doc false
  def sync_litellm_gateway_on_node(node_name, attrs, timeout \\ 120_000) when is_map(attrs) do
    native_command_on_node(
      node_name,
      attrs,
      timeout,
      &sync_litellm_gateway/2,
      "LiteLLM gateway sync request",
      "the matching gRPC command"
    )
  end

  @doc false
  def remove_litellm_gateway_route_on_node(node_name, attrs, timeout \\ 120_000)
      when is_map(attrs) do
    native_command_on_node(
      node_name,
      attrs,
      timeout,
      &remove_litellm_gateway_route/2,
      "LiteLLM gateway route removal request",
      "the matching gRPC command"
    )
  end

  @doc false
  def prepare_docker_worker_on_node(node_name, request, timeout \\ 1_800_000) do
    native_request_on_node(
      node_name,
      request,
      timeout,
      &prepare_docker_worker/2,
      "DockerWorker preparation request",
      "PrepareDockerWorker gRPC"
    )
  end

  @doc false
  def cleanup_docker_worker_on_node(node_name, request, timeout \\ 120_000) do
    native_request_on_node(
      node_name,
      request,
      timeout,
      &cleanup_docker_worker/2,
      "DockerWorker cleanup request",
      "CleanupDockerWorker gRPC"
    )
  end

  @doc false
  def prepare_docker_compose_on_node(node_name, request, timeout \\ 1_800_000) do
    native_request_on_node(
      node_name,
      request,
      timeout,
      &prepare_docker_compose/2,
      "DockerCompose preparation request",
      "PrepareDockerCompose gRPC"
    )
  end

  @doc false
  def docker_compose_status_on_node(node_name, request, timeout \\ 30_000) do
    native_request_on_node(
      node_name,
      request,
      timeout,
      &docker_compose_status/2,
      "DockerCompose status request",
      "GetDockerComposeStatus gRPC"
    )
  end

  @doc false
  def cleanup_docker_compose_on_node(node_name, request, timeout \\ 120_000) do
    native_request_on_node(
      node_name,
      request,
      timeout,
      &cleanup_docker_compose/2,
      "DockerCompose cleanup request",
      "CleanupDockerCompose gRPC"
    )
  end

  defp native_command_on_node(node_name, attrs, timeout, local_fun, description, command_hint) do
    target_node = Requests.normalize_node_name(node_name)
    self_node = to_string(Node.self())

    cond do
      target_node in [nil, "", self_node] ->
        local_fun.(attrs, timeout)

      true ->
        {:error,
         "#{description} for #{target_node} reached #{self_node}; send #{command_hint} to the target node runtime so its local mn-python-sdk can prepare native resources"}
    end
  end

  defp native_request_on_node(node_name, request, timeout, local_fun, description, command_hint) do
    target_node = Requests.normalize_node_name(node_name)
    self_node = to_string(Node.self())

    cond do
      target_node in [nil, "", self_node] ->
        local_fun.(request, timeout)

      true ->
        {:error,
         "#{description} for #{target_node} reached #{self_node}; send #{command_hint} to the target node native SDK service"}
    end
  end

  @doc false
  def prepare_runtime_model(attrs, timeout \\ 1_200_000) when is_map(attrs) do
    with {:ok, attrs} <- Models.normalize_runtime_model_prepare_attrs(attrs),
         {:ok, target} <- Requests.native_sdk_grpc_target(),
         {:ok, response} <- Transport.native_sdk_prepare(target, attrs, timeout),
         {:ok, result} when is_map(result) <- Jason.decode(response.resource_json) do
      {:ok, result}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         "native SDK runtime model prepare returned invalid JSON: #{Exception.message(error)}"}

      {:ok, _other} ->
        {:error, "native SDK runtime model prepare returned a non-object response"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def prepare_docker_worker(%PrepareDockerWorkerRequest{} = request, timeout \\ 1_800_000) do
    Requests.native_sdk_proto_command(
      request,
      timeout,
      :native_sdk_grpc_prepare_docker_worker_client,
      &MirrorNeuron.ModelServices.grpc_prepare_docker_worker/3,
      "native SDK DockerWorker preparation"
    )
  end

  @doc false
  def cleanup_docker_worker(%CleanupDockerWorkerRequest{} = request, timeout \\ 120_000) do
    Requests.native_sdk_proto_command(
      request,
      timeout,
      :native_sdk_grpc_cleanup_docker_worker_client,
      &MirrorNeuron.ModelServices.grpc_cleanup_docker_worker/3,
      "native SDK DockerWorker cleanup"
    )
  end

  @doc false
  def prepare_docker_compose(%PrepareDockerComposeRequest{} = request, timeout \\ 1_800_000) do
    Requests.native_sdk_proto_command(
      request,
      timeout,
      :native_sdk_grpc_prepare_docker_compose_client,
      &MirrorNeuron.ModelServices.grpc_prepare_docker_compose/3,
      "native SDK DockerCompose preparation"
    )
  end

  @doc false
  def docker_compose_status(%DockerComposeStatusRequest{} = request, timeout \\ 30_000) do
    Requests.native_sdk_proto_command(
      request,
      timeout,
      :native_sdk_grpc_docker_compose_status_client,
      &MirrorNeuron.ModelServices.grpc_docker_compose_status/3,
      "native SDK DockerCompose status"
    )
  end

  @doc false
  def cleanup_docker_compose(%CleanupDockerComposeRequest{} = request, timeout \\ 120_000) do
    Requests.native_sdk_proto_command(
      request,
      timeout,
      :native_sdk_grpc_cleanup_docker_compose_client,
      &MirrorNeuron.ModelServices.grpc_cleanup_docker_compose/3,
      "native SDK DockerCompose cleanup"
    )
  end

  @doc false
  def sync_litellm_gateway(attrs, timeout \\ 120_000) when is_map(attrs) do
    Requests.native_sdk_json_command(
      attrs,
      timeout,
      :native_sdk_grpc_sync_client,
      &MirrorNeuron.ModelServices.grpc_sync_litellm_gateway/3,
      "native SDK LiteLLM gateway sync"
    )
  end

  @doc false
  def remove_litellm_gateway_route(attrs, timeout \\ 120_000) when is_map(attrs) do
    Requests.native_sdk_json_command(
      attrs,
      timeout,
      :native_sdk_grpc_remove_gateway_route_client,
      &MirrorNeuron.ModelServices.grpc_remove_litellm_gateway_route/3,
      "native SDK LiteLLM gateway route removal"
    )
  end

  @doc false
  def job_response_command(attrs, timeout \\ 60_000) when is_map(attrs) do
    Requests.native_sdk_json_command(
      attrs,
      timeout,
      :native_sdk_grpc_job_response_client,
      &MirrorNeuron.ModelServices.grpc_set_resource/3,
      "native SDK Job response command"
    )
  end

  @doc false
  def native_resource_command(attrs, timeout \\ 120_000) when is_map(attrs) do
    Requests.native_sdk_json_command(
      Map.put(attrs, "kind", "native_resource"),
      timeout,
      :native_sdk_grpc_native_resource_client,
      &MirrorNeuron.ModelServices.grpc_set_resource/3,
      "native SDK resource lifecycle command"
    )
  end
end
