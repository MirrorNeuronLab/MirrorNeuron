defmodule MirrorNeuron.ModelServices.Requests do
  @moduledoc "Encodes SDK requests, decodes responses and bounds configured timeouts."

  alias Mirrorneuron.Cluster.V1.SetResourceRequest

  @interface_version 1
  @native_sdk_grpc_target_env "MN_NATIVE_SDK_GRPC_TARGET"
  @native_sdk_grpc_timeout_env "MN_NATIVE_SDK_GRPC_TIMEOUT_MS"

  def native_sdk_json_command(attrs, timeout, client_env, default_client, label) do
    with {:ok, target} <- native_sdk_grpc_target(),
         {:ok, response} <-
           native_sdk_request(target, attrs, timeout, client_env, default_client),
         {:ok, result} when is_map(result) <- Jason.decode(response.resource_json) do
      {:ok, result}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "#{label} returned invalid JSON: #{Exception.message(error)}"}

      {:ok, _other} ->
        {:error, "#{label} returned a non-object response"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def native_sdk_proto_command(request, timeout, client_env, default_client, label) do
    with {:ok, target} <- native_sdk_grpc_target(),
         {:ok, response} <-
           native_sdk_proto_request(target, request, timeout, client_env, default_client) do
      {:ok, response}
    else
      {:error, reason} -> {:error, "#{label} failed: #{error_message(reason)}"}
    end
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp error_message(reason), do: inspect(reason)

  def native_sdk_request(target, attrs, timeout, client_env, default_client) do
    request = %SetResourceRequest{
      resource_json: Jason.encode!(attrs),
      version: @interface_version
    }

    client =
      Application.get_env(
        :mirror_neuron,
        client_env,
        default_client
      )

    client.(target, request, native_sdk_timeout(timeout))
  end

  defp native_sdk_proto_request(target, request, timeout, client_env, default_client) do
    client = Application.get_env(:mirror_neuron, client_env, default_client)
    client.(target, request, native_sdk_timeout(timeout))
  end

  def native_sdk_grpc_target do
    case System.get_env(@native_sdk_grpc_target_env) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, native_sdk_unavailable_message()}, else: {:ok, value}

      _ ->
        {:error, native_sdk_unavailable_message()}
    end
  end

  defp native_sdk_unavailable_message do
    "runtime model preparation is owned by mn-python-sdk/API/CLI; #{inspect(@native_sdk_grpc_target_env)} is not configured, so Core cannot forward this request to the node-local SDK service"
  end

  defp native_sdk_timeout(timeout) when is_integer(timeout) and timeout > 0 do
    env_timeout =
      @native_sdk_grpc_timeout_env
      |> System.get_env()
      |> parse_positive_integer()

    env_timeout || timeout
  end

  defp native_sdk_timeout(_timeout), do: 1_200_000

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  def normalize_node_name(value) when is_atom(value),
    do: value |> to_string() |> normalize_node_name()

  def normalize_node_name(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def normalize_node_name(_value), do: nil
end
