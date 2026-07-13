defmodule MirrorNeuron.Grpc.Handlers.DockerWorker do
  @moduledoc false

  alias MirrorNeuron.ModelServices

  def prepare_docker_worker(request, _stream) do
    dispatch(&ModelServices.prepare_docker_worker_on_node/2, request.node_name, request)
  end

  def cleanup_docker_worker(request, _stream) do
    dispatch(&ModelServices.cleanup_docker_worker_on_node/2, nil, request)
  end

  defp dispatch(fun, node_name, request) do
    case fun.(node_name, request) do
      {:ok, response} ->
        response

      {:error, reason} ->
        raise GRPC.RPCError, status: :failed_precondition, message: to_string(reason)
    end
  end
end
