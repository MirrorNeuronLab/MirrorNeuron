defmodule MirrorNeuron.Grpc.Handlers.DockerCompose do
  @moduledoc false

  alias MirrorNeuron.ModelServices

  def prepare_docker_compose(request, _stream) do
    dispatch(&ModelServices.prepare_docker_compose_on_node/2, request.node_name, request)
  end

  def get_docker_compose_status(request, _stream) do
    dispatch(&ModelServices.docker_compose_status_on_node/2, nil, request)
  end

  def cleanup_docker_compose(request, _stream) do
    dispatch(&ModelServices.cleanup_docker_compose_on_node/2, nil, request)
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
