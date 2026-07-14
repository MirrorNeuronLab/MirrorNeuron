defmodule MirrorNeuron.Grpc.Handlers.Service do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Grpc.Handlers.Support

  alias Mirrorneuron.Cluster.V1.{
    CheckServicesResponse,
    ListServicesResponse,
    ResolveServiceResponse
  }

  def list_services(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListServices")

    opts = query_opts(request.query_json)

    case MirrorNeuron.list_services(opts) do
      {:ok, services} ->
        %ListServicesResponse{
          result_json: Support.versioned_json(%{"services" => services}),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def resolve_service(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ResolveService")

    opts = query_opts(request.query_json)

    case MirrorNeuron.resolve_service(request.name, opts) do
      {:ok, services} ->
        %ResolveServiceResponse{
          result_json: Support.versioned_json(%{"services" => services}),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
    end
  end

  def check_services(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CheckServices")

    with {:ok, services} <- decode_json(request.services_json, []) do
      case MirrorNeuron.check_services(services) do
        {:ok, result} ->
          %CheckServicesResponse{
            result_json: Support.versioned_json(result),
            version: @interface_version
          }

        {:error, reason} ->
          raise GRPC.RPCError, status: GRPC.Status.internal(), message: inspect(reason)
      end
    else
      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.invalid_argument(), message: reason
    end
  end

  defp query_opts(json) do
    json
    |> decode_json(%{})
    |> case do
      {:ok, query} when is_map(query) ->
        query
        |> Enum.flat_map(fn {key, value} ->
          case key do
            "name" -> [name: value]
            "node" -> [node: value]
            "job_id" -> [job_id: value]
            "agent_id" -> [agent_id: value]
            "status" -> [status: value]
            "tags" -> [tags: value]
            "passing_only" -> [passing_only: value]
            _ -> []
          end
        end)
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

      _ ->
        []
    end
  end

  defp decode_json("", default), do: {:ok, default}
  defp decode_json(nil, default), do: {:ok, default}

  defp decode_json(json, _default) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, "body must be valid JSON: #{Exception.message(error)}"}
    end
  end
end
