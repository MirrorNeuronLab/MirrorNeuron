defmodule MirrorNeuron.ModelServices do
  @moduledoc false

  alias MirrorNeuron.ServiceRegistry
  alias Mirrorneuron.Cluster.V1.ClusterService
  alias Mirrorneuron.Cluster.V1.CleanupDockerWorkerRequest
  alias Mirrorneuron.Cluster.V1.PrepareDockerWorkerRequest
  alias Mirrorneuron.Cluster.V1.SetResourceRequest

  @interface_version 1
  @active_node_statuses ["healthy", "joining"]
  @native_sdk_grpc_target_env "MN_NATIVE_SDK_GRPC_TARGET"
  @native_sdk_grpc_timeout_env "MN_NATIVE_SDK_GRPC_TIMEOUT_MS"
  @default_llm_model "gemma4:e2b"
  @default_context_engine_model "hf.co/homerquan/mn-context-engine-model-v-Q4_K_M"
  @default_knowledge_rag_model "huggingface.co/jinaai/jina-embeddings-v5-text-small-retrieval:Q4_K_M"
  @service_env_vars [
    "MN_NODE_SERVICES_JSON",
    "MN_MODEL_SERVICES_JSON"
  ]
  @model_env_vars [
    "MN_NODE_MODELS",
    "MN_NODE_RUNTIME_MODELS",
    "MN_DOCKER_MODEL_RUNNER_MODEL",
    "MN_LLM_MODEL_RUNNER_MODEL",
    "MN_LLM_RUNTIME_MODEL"
  ]
  @model_runner_endpoint_env_vars [
    "MN_DOCKER_MODEL_RUNNER_API_BASE",
    "MN_MODEL_RUNNER_API_BASE",
    "DOCKER_MODEL_RUNNER_API_BASE",
    "MODEL_RUNNER_HOST",
    "MN_LLM_API_BASE"
  ]
  @model_service_node_env "MN_MODEL_SERVICE_NODE_NAME"
  @network_advertise_host_env "MN_NETWORK_ADVERTISE_HOST"
  @default_node_name "mirror_neuron"

  @doc false
  def env_model_refs(env \\ System.get_env()) when is_map(env) do
    @model_env_vars
    |> Enum.flat_map(fn name ->
      env
      |> Map.get(name)
      |> split_env_list()
    end)
    |> Enum.uniq()
  end

  @doc false
  def service_instances_for_models(_model_refs, _node_name, _catalog \\ nil) do
    []
  end

  @doc false
  def service_instances_for_env(env, node_name, _catalog \\ nil) when is_map(env) do
    env
    |> explicit_service_instances(node_name)
    |> Enum.map(&with_runtime_health_check(&1, env))
  end

  @doc false
  def advertise_env_models(node_name \\ Node.self(), env \\ System.get_env()) when is_map(env) do
    node_name = advertised_node_name(node_name, env)
    services = service_instances_for_env(env, node_name)
    register_model_services(services, node_name)
  end

  @doc false
  def advertise_models(_model_refs, node_name \\ Node.self(), env \\ System.get_env())
      when is_map(env) do
    node_name = advertised_node_name(node_name, env)
    services = service_instances_for_env(env, node_name)
    register_model_services(services, node_name)
  end

  @doc false
  def persist_node_runtime_model(_model_ref, _env \\ System.get_env()), do: :ok

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

  defp native_command_on_node(node_name, attrs, timeout, local_fun, description, command_hint) do
    target_node = normalize_node_name(node_name)
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
    target_node = normalize_node_name(node_name)
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
    with {:ok, attrs} <- normalize_runtime_model_prepare_attrs(attrs),
         {:ok, target} <- native_sdk_grpc_target(),
         {:ok, response} <- native_sdk_prepare(target, attrs, timeout),
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
    native_sdk_proto_command(
      request,
      timeout,
      :native_sdk_grpc_prepare_docker_worker_client,
      &__MODULE__.grpc_prepare_docker_worker/3,
      "native SDK DockerWorker preparation"
    )
  end

  @doc false
  def cleanup_docker_worker(%CleanupDockerWorkerRequest{} = request, timeout \\ 120_000) do
    native_sdk_proto_command(
      request,
      timeout,
      :native_sdk_grpc_cleanup_docker_worker_client,
      &__MODULE__.grpc_cleanup_docker_worker/3,
      "native SDK DockerWorker cleanup"
    )
  end

  @doc false
  def sync_litellm_gateway(attrs, timeout \\ 120_000) when is_map(attrs) do
    native_sdk_json_command(
      attrs,
      timeout,
      :native_sdk_grpc_sync_client,
      &__MODULE__.grpc_sync_litellm_gateway/3,
      "native SDK LiteLLM gateway sync"
    )
  end

  @doc false
  def remove_litellm_gateway_route(attrs, timeout \\ 120_000) when is_map(attrs) do
    native_sdk_json_command(
      attrs,
      timeout,
      :native_sdk_grpc_remove_gateway_route_client,
      &__MODULE__.grpc_remove_litellm_gateway_route/3,
      "native SDK LiteLLM gateway route removal"
    )
  end

  defp register_model_services(services, node_name) do
    case services do
      [] ->
        :ok

      services ->
        with {:ok, registered} <- ServiceRegistry.register_many(services) do
          prune_stale_model_services(registered, node_name)
          {:ok, registered}
        end
    end
  rescue
    _ -> :ok
  end

  @doc false
  def grpc_prepare_runtime_model(target, request, timeout) do
    with {:ok, channel} <- GRPC.Stub.connect(target, timeout: timeout),
         {:ok, response} <-
           ClusterService.Stub.prepare_runtime_model(channel, request, timeout: timeout) do
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
    with {:ok, channel} <- GRPC.Stub.connect(target, timeout: timeout),
         {:ok, response} <-
           ClusterService.Stub.prepare_docker_worker(channel, request, timeout: timeout) do
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
    with {:ok, channel} <- GRPC.Stub.connect(target, timeout: timeout),
         {:ok, response} <-
           ClusterService.Stub.cleanup_docker_worker(channel, request, timeout: timeout) do
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
  def grpc_sync_litellm_gateway(target, request, timeout) do
    with {:ok, channel} <- GRPC.Stub.connect(target, timeout: timeout),
         {:ok, response} <-
           ClusterService.Stub.sync_lite_llm_gateway(channel, request, timeout: timeout) do
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
    with {:ok, channel} <- GRPC.Stub.connect(target, timeout: timeout),
         {:ok, response} <-
           ClusterService.Stub.remove_lite_llm_gateway_route(channel, request, timeout: timeout) do
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

  defp native_sdk_prepare(target, attrs, timeout) do
    case native_sdk_request(
           target,
           attrs,
           timeout,
           :native_sdk_grpc_client,
           &__MODULE__.grpc_prepare_runtime_model/3
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

  defp normalize_runtime_model_prepare_attrs(attrs) when is_map(attrs) do
    case runtime_model_for_prepare_purpose(prepare_model_ref(attrs), prepare_model_purpose(attrs)) do
      {:ok, model} ->
        {:ok,
         attrs
         |> Map.put("model", model)
         |> Map.put("runtime_model", model)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_model_ref(attrs) do
    attrs
    |> first_present(["model", :model, "runtime_model", :runtime_model, "id", :id])
    |> to_string()
    |> String.trim()
  end

  defp prepare_model_purpose(attrs) do
    attrs
    |> first_present(["purpose", :purpose, "model_purpose", :model_purpose])
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp runtime_model_for_prepare_purpose("", purpose) do
    case purpose do
      "" -> {:ok, @default_llm_model}
      "llm" -> {:ok, @default_llm_model}
      "runtime" -> {:ok, @default_llm_model}
      "runtime_llm" -> {:ok, @default_llm_model}
      "default" -> {:ok, @default_llm_model}
      "context" -> {:ok, @default_context_engine_model}
      "context_engine" -> {:ok, @default_context_engine_model}
      "context_model" -> {:ok, @default_context_engine_model}
      "context_engine_model" -> {:ok, @default_context_engine_model}
      "knowledge_rag" -> {:ok, @default_knowledge_rag_model}
      "rag" -> {:ok, @default_knowledge_rag_model}
      "embedding" -> {:ok, @default_knowledge_rag_model}
      "knowledge_rag_embedding" -> {:ok, @default_knowledge_rag_model}
      other -> {:error, "unsupported runtime model prepare purpose: #{other}"}
    end
  end

  defp runtime_model_for_prepare_purpose("default", _purpose), do: {:ok, @default_llm_model}
  defp runtime_model_for_prepare_purpose(model, _purpose), do: {:ok, model}

  defp first_present(attrs, keys) do
    Enum.find_value(keys, "", fn key ->
      case Map.get(attrs, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp native_sdk_json_command(attrs, timeout, client_env, default_client, label) do
    with {:ok, target} <- native_sdk_grpc_target(),
         {:ok, response} <- native_sdk_request(target, attrs, timeout, client_env, default_client),
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

  defp native_sdk_proto_command(request, timeout, client_env, default_client, label) do
    with {:ok, target} <- native_sdk_grpc_target(),
         {:ok, response} <-
           native_sdk_proto_request(target, request, timeout, client_env, default_client) do
      {:ok, response}
    else
      {:error, reason} -> {:error, "#{label} failed: #{reason}"}
    end
  end

  defp native_sdk_request(target, attrs, timeout, client_env, default_client) do
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

  defp native_sdk_grpc_target do
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

  defp normalize_node_name(value) when is_atom(value),
    do: value |> to_string() |> normalize_node_name()

  defp normalize_node_name(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_node_name(_value), do: nil

  @doc false
  def advertised_node_name(node_name \\ Node.self(), env \\ System.get_env()) when is_map(env) do
    cond do
      explicit = normalized_env(env, @model_service_node_env) ->
        explicit

      host = normalized_env(env, @network_advertise_host_env) ->
        "#{node_prefix(node_name)}@#{host}"

      true ->
        to_string(node_name)
    end
  end

  defp with_runtime_health_check(%{"name" => "docker-model-runner"} = service, env) do
    case Map.get(service, "address") || model_runner_endpoint(env) do
      nil ->
        service

      endpoint ->
        check = %{
          "name" => "docker-model-runner",
          "type" => "http",
          "url" => "#{String.trim_trailing(endpoint, "/")}/models",
          "timeout_ms" => 3_000,
          "failures_before_critical" => 1
        }

        service
        |> Map.put("address", endpoint)
        |> Map.update("checks", [check], fn checks -> [check | List.wrap(checks)] end)
    end
  end

  defp with_runtime_health_check(service, _env), do: service

  defp model_runner_endpoint(env) do
    @model_runner_endpoint_env_vars
    |> Enum.find_value(&normalized_env(env, &1))
  end

  defp explicit_service_instances(env, node_name) do
    @service_env_vars
    |> Enum.flat_map(fn name ->
      env
      |> Map.get(name)
      |> decode_service_instances()
    end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {service, index} ->
      normalize_service_instance(service, node_name, index)
    end)
    |> Enum.uniq_by(&Map.get(&1, "id"))
  end

  defp decode_service_instances(nil), do: []
  defp decode_service_instances(""), do: []

  defp decode_service_instances(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decode_service_instances(decoded)
      {:error, _reason} -> []
    end
  end

  defp decode_service_instances(%{"services" => services}), do: decode_service_instances(services)

  defp decode_service_instances(%{} = services_by_name) do
    if service_instance_map?(services_by_name) do
      [services_by_name]
    else
      services_by_name
      |> Map.values()
      |> decode_service_instances()
    end
  end

  defp decode_service_instances(values) when is_list(values), do: Enum.filter(values, &is_map/1)
  defp decode_service_instances(_value), do: []

  defp service_instance_map?(value) when is_map(value) do
    Map.has_key?(value, "name") or Map.has_key?(value, :name) or Map.has_key?(value, "service") or
      Map.has_key?(value, :service)
  end

  defp normalize_service_instance(service, node_name, index) when is_map(service) do
    service = stringify_keys(service)
    name = normalized_map_value(service, "name") || normalized_map_value(service, "service")

    if name in [nil, ""] do
      []
    else
      node = normalized_map_value(service, "node") || to_string(node_name)
      tags = normalize_tags(Map.get(service, "tags", []))
      meta = normalize_meta(Map.get(service, "meta", %{}))
      model_key = service_model_key(service, meta, tags) || Integer.to_string(index)

      normalized =
        service
        |> Map.put("name", name)
        |> Map.put("node", node)
        |> Map.put("tags", tags)
        |> Map.put("meta", meta)
        |> Map.put_new("id", "#{node}:#{name}:#{model_key}")
        |> Map.put_new("provider", "mirror_neuron")
        |> Map.put_new("origin", "external")
        |> Map.put_new("status", "passing")
        |> Map.delete("service")

      [normalized]
    end
  end

  defp normalize_service_instance(_service, _node_name, _index), do: []

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp normalize_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_meta(meta) when is_map(meta), do: stringify_keys(meta)
  defp normalize_meta(_meta), do: %{}

  defp service_model_key(service, meta, tags) do
    normalized_map_value(meta, "model_id") ||
      normalized_map_value(meta, "model") ||
      normalized_map_value(service, "model") ||
      Enum.find_value(tags, fn tag ->
        case String.split(to_string(tag), ":", parts: 2) do
          ["model-id", value] -> normalize_id_part(value)
          ["model", value] -> normalize_id_part(value)
          _ -> nil
        end
      end)
  end

  defp normalize_id_part(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.:-]+/, "-")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalized_map_value(map, key) when is_map(map) do
    map
    |> Map.get(key)
    |> case do
      nil ->
        nil

      value ->
        value
        |> to_string()
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end
    end
  end

  defp normalized_map_value(_map, _key), do: nil

  defp prune_stale_model_services(services, node_name) do
    model_ids =
      services
      |> Enum.map(&model_service_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if MapSet.size(model_ids) == 0 do
      :ok
    else
      active_nodes = active_node_names()

      case ServiceRegistry.list() do
        {:ok, existing} ->
          existing
          |> Enum.filter(&stale_model_service?(&1, node_name, model_ids, active_nodes))
          |> Enum.each(fn service -> ServiceRegistry.deregister_service(service["id"]) end)

          :ok

        _ ->
          :ok
      end
    end
  end

  defp stale_model_service?(service, current_node, model_ids, active_nodes) do
    service_node = Map.get(service, "node")

    Map.get(service, "name") == "docker-model-runner" and
      service_node != current_node and
      not MapSet.member?(active_nodes, service_node) and
      MapSet.member?(model_ids, model_service_id(service))
  end

  defp model_service_id(service) do
    get_in(service, ["meta", "model_id"]) ||
      service
      |> Map.get("tags", [])
      |> List.wrap()
      |> Enum.find_value(fn tag ->
        case String.split(to_string(tag), "model-id:", parts: 2) do
          ["", value] -> value
          _ -> nil
        end
      end)
  end

  defp active_node_names do
    MirrorNeuron.Cluster.NodeState.list()
    |> Enum.filter(&(Map.get(&1, "status") in @active_node_statuses))
    |> Enum.map(&Map.get(&1, "node", Map.get(&1, "name")))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  defp split_env_list(nil), do: []

  defp split_env_list(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalized_env(env, key) do
    env
    |> Map.get(key)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp node_prefix(node_name) do
    node_name
    |> to_string()
    |> String.split("@", parts: 2)
    |> case do
      [prefix, _host] when prefix != "" -> prefix
      _ -> @default_node_name
    end
  end
end
