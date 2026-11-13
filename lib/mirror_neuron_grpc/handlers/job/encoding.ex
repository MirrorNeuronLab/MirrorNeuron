defmodule MirrorNeuron.Grpc.Handlers.Job.Encoding do
  @moduledoc "Maps runtime results into versioned JSON responses and semantic gRPC errors."

  alias MirrorNeuron.Grpc.JobProjection
  alias Mirrorneuron.Job.V1.JsonResponse
  alias MirrorNeuron.Grpc.Handlers.Support

  @interface_version 1

  def respond_definition({:ok, definition}, :summary),
    do: response(JobProjection.summary(definition))

  def respond_definition(error, _projection), do: respond(error)

  def respond({:ok, value}), do: response(value)

  def respond({:error, reason}) do
    Support.raise_runtime_error!(reason)
  end

  def respond(other), do: response(other)

  def response(value) do
    %JsonResponse{
      result_json: Jason.encode!(value),
      version: @interface_version,
      revision: revision(value),
      next_page_token: if(is_map(value), do: value["next_page_token"] || "", else: "")
    }
  end

  defp revision(%{"revision" => revision}) when is_integer(revision), do: revision

  defp revision(_value), do: 0

  def page_size(0), do: 50

  def page_size(value), do: value
end
