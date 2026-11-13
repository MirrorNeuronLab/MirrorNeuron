defmodule MirrorNeuron.ModelServices.Transport do
  @moduledoc "Executes native SDK gRPC calls and preserves model-preparation status codes."

  alias Mirrorneuron.Cluster.V1.ClusterService
  alias MirrorNeuron.NativeSdkClient
  alias MirrorNeuron.ModelServices.Requests

  @doc false
  def grpc_prepare_runtime_model(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(
             target,
             request,
             timeout,
             &ClusterService.Stub.prepare_runtime_model/3
           ) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        # The native SDK uses gRPC status codes to distinguish a model that
        # cannot run from a node-local service that cannot be reached. Preserve
        # that contract for the caller instead of flattening it into a generic
        # Core precondition failure.
        {:error, error}

      {:error, reason} ->
        {:error,
         GRPC.RPCError.exception(
           :unavailable,
           "native SDK gRPC prepare is unavailable for #{target}: #{inspect(reason)}"
         )}
    end
  end

  @doc false
  def grpc_prepare_docker_worker(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(
             target,
             request,
             timeout,
             &ClusterService.Stub.prepare_docker_worker/3
           ) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error,
         "native SDK gRPC DockerWorker preparation failed for #{target}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error,
         "native SDK gRPC DockerWorker preparation failed for #{target}: #{inspect(reason)}"}
    end
  end

  @doc false
  def grpc_cleanup_docker_worker(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(
             target,
             request,
             timeout,
             &ClusterService.Stub.cleanup_docker_worker/3
           ) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error,
         "native SDK gRPC DockerWorker cleanup failed for #{target}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "native SDK gRPC DockerWorker cleanup failed for #{target}: #{inspect(reason)}"}
    end
  end

  @doc false
  def grpc_prepare_docker_compose(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(
             target,
             request,
             timeout,
             &ClusterService.Stub.prepare_docker_compose/3
           ) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error,
         "native SDK gRPC DockerCompose preparation failed for #{target}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error,
         "native SDK gRPC DockerCompose preparation failed for #{target}: #{inspect(reason)}"}
    end
  end

  @doc false
  def grpc_docker_compose_status(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(
             target,
             request,
             timeout,
             &ClusterService.Stub.get_docker_compose_status/3
           ) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error,
         "native SDK gRPC DockerCompose status failed for #{target}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "native SDK gRPC DockerCompose status failed for #{target}: #{inspect(reason)}"}
    end
  end

  @doc false
  def grpc_cleanup_docker_compose(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(
             target,
             request,
             timeout,
             &ClusterService.Stub.cleanup_docker_compose/3
           ) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error,
         "native SDK gRPC DockerCompose cleanup failed for #{target}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "native SDK gRPC DockerCompose cleanup failed for #{target}: #{inspect(reason)}"}
    end
  end

  @doc false
  def grpc_sync_litellm_gateway(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(
             target,
             request,
             timeout,
             &ClusterService.Stub.sync_lite_llm_gateway/3
           ) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error,
         "native SDK gRPC LiteLLM gateway sync failed for #{target}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "native SDK gRPC LiteLLM gateway sync failed for #{target}: #{inspect(reason)}"}
    end
  end

  @doc false
  def grpc_remove_litellm_gateway_route(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(
             target,
             request,
             timeout,
             &ClusterService.Stub.remove_lite_llm_gateway_route/3
           ) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error,
         "native SDK gRPC LiteLLM gateway route removal failed for #{target}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error,
         "native SDK gRPC LiteLLM gateway route removal failed for #{target}: #{inspect(reason)}"}
    end
  end

  @doc false
  def grpc_set_resource(target, request, timeout) do
    with {:ok, response} <-
           NativeSdkClient.call(target, request, timeout, &ClusterService.Stub.set_resource/3) do
      {:ok, response}
    else
      {:error, %GRPC.RPCError{} = error} ->
        {:error,
         "native SDK gRPC resource command failed for #{target}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "native SDK gRPC resource command failed for #{target}: #{inspect(reason)}"}
    end
  end

  def native_sdk_prepare(target, attrs, timeout) do
    case Requests.native_sdk_request(
           target,
           attrs,
           timeout,
           :native_sdk_grpc_client,
           &MirrorNeuron.ModelServices.grpc_prepare_runtime_model/3
         ) do
      {:error, %GRPC.RPCError{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         GRPC.RPCError.exception(
           :unavailable,
           "native SDK gRPC prepare is unavailable for #{target}: #{inspect(reason)}"
         )}

      result ->
        result
    end
  end
end
