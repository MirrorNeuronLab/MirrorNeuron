defmodule MirrorNeuron.ModelServices do
  @moduledoc false

  alias MirrorNeuron.ModelCatalog
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.ServiceRegistry

  @active_node_statuses ["healthy", "joining"]
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
  @model_remotes_path_env "MN_MODEL_REMOTES_PATH"
  @runtime_compose_env_path_env "MN_RUNTIME_COMPOSE_ENV"
  @default_node_name "mirror_neuron"

  def env_model_refs(env \\ System.get_env()) when is_map(env) do
    @model_env_vars
    |> Enum.flat_map(fn name ->
      env
      |> Map.get(name)
      |> split_env_list()
    end)
    |> Enum.uniq()
  end

  def service_instances_for_models(model_refs, node_name, catalog \\ ModelCatalog.load_catalog()) do
    model_refs
    |> List.wrap()
    |> Enum.flat_map(fn model_ref ->
      case ModelCatalog.resolve(model_ref, catalog) do
        {:ok, entry} -> [entry]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq_by(&(ModelCatalog.model_id(&1) || ModelCatalog.docker_model_name(&1)))
    |> Enum.map(&ModelCatalog.service_instance(&1, node_name))
  end

  def service_instances_for_env(env, node_name, catalog \\ ModelCatalog.load_catalog())
      when is_map(env) do
    env
    |> env_model_refs()
    |> service_instances_for_models(node_name, catalog)
    |> Kernel.++(remote_service_instances(env, node_name, catalog))
    |> Enum.map(&with_runtime_health_check(&1, env))
  end

  def advertise_env_models(node_name \\ Node.self(), env \\ System.get_env()) when is_map(env) do
    node_name = advertised_node_name(node_name, env)
    services = service_instances_for_env(env, node_name)
    register_model_services(services, node_name)
  end

  def advertise_models(model_refs, node_name \\ Node.self(), env \\ System.get_env())
      when is_map(env) do
    node_name = advertised_node_name(node_name, env)

    services =
      model_refs
      |> service_instances_for_models(node_name)
      |> Enum.map(&with_runtime_health_check(&1, env))

    register_model_services(services, node_name)
  end

  def persist_node_runtime_model(model_ref, env \\ System.get_env()) do
    model_ref = model_ref |> to_string() |> String.trim()

    if model_ref != "" do
      env
      |> runtime_compose_env_path()
      |> upsert_runtime_model_ref(model_ref)
    end

    :ok
  rescue
    _ -> :ok
  end

  def prepare_runtime_model_on_node(node_name, attrs, timeout \\ 1_200_000) when is_map(attrs) do
    target = normalize_node_name(node_name)

    cond do
      target in ["", to_string(NodeAdapter.self())] ->
        prepare_runtime_model(attrs)

      true ->
        case NodeAdapter.rpc_call(
               String.to_atom(target),
               __MODULE__,
               :prepare_runtime_model,
               [attrs],
               timeout
             ) do
          {:badrpc, reason} ->
            {:error, "failed to prepare runtime model on #{target}: #{inspect(reason)}"}

          other ->
            other
        end
    end
  end

  def prepare_runtime_model(attrs) when is_map(attrs) do
    model_ref = normalized_value(attrs, "model") || normalized_value(attrs, :model)
    backend = normalized_value(attrs, "backend") || normalized_value(attrs, :backend) || "auto"

    cond do
      model_ref in [nil, ""] ->
        {:error, "runtime model is required"}

      true ->
        do_prepare_runtime_model(model_ref, backend)
    end
  end

  defp do_prepare_runtime_model(model_ref, backend) do
    docker = System.find_executable("docker") || "docker"
    env = System.get_env()

    with :ok <- ensure_docker_model(docker, model_ref),
         :ok <- persist_node_runtime_model(model_ref, env) do
      _ = advertise_models([model_ref], NodeAdapter.self(), env)

      {:ok,
       %{
         "status" => "installed",
         "model" => model_ref,
         "backend" => backend,
         "node" => to_string(NodeAdapter.self()),
         "endpoint" => runtime_model_endpoint(model_ref, env)
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, inspect(other)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp ensure_docker_model(docker, model_ref) do
    case System.cmd(docker, ["model", "inspect", model_ref], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      _ ->
        with {_pull_output, 0} <-
               System.cmd(docker, ["model", "pull", model_ref], stderr_to_stdout: true),
             {_run_output, 0} <-
               System.cmd(docker, ["model", "run", "--detach", model_ref], stderr_to_stdout: true) do
          :ok
        else
          {output, _exit_code} ->
            {:error, String.trim(output)}
        end
    end
  end

  defp runtime_model_endpoint(model_ref, env) do
    node = to_string(NodeAdapter.self())
    host = node_host(node)

    api_base =
      case model_runner_endpoint(env) do
        nil -> "http://#{host}:12434/engines/v1"
        value -> public_model_runner_endpoint(value, host)
      end

    %{
      "provider" => "docker_model_runner",
      "model" => model_ref,
      "runtime_model" => model_ref,
      "api_model" => model_ref,
      "api_base" => api_base,
      "node" => node,
      "source" => "cluster_node_install"
    }
  end

  defp public_model_runner_endpoint(value, host) do
    value = String.trim_trailing(to_string(value), "/")

    cond do
      String.contains?(value, "host.docker.internal") or
        String.contains?(value, "127.0.0.1") or
          String.contains?(value, "localhost") ->
        "http://#{host}:12434/engines/v1"

      true ->
        value
    end
  end

  defp node_host(node) do
    case String.split(to_string(node), "@", parts: 2) do
      [_name, host] when host != "" -> host
      _ -> "host.docker.internal"
    end
  end

  defp normalize_node_name(value) do
    value
    |> to_string()
    |> String.trim()
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

  defp remote_service_instances(env, node_name, catalog) do
    env
    |> model_remotes_path()
    |> read_model_remotes()
    |> Enum.flat_map(&remote_service_instance(&1, node_name, catalog))
  end

  defp model_remotes_path(env) do
    normalized_env(env, @model_remotes_path_env) ||
      Path.join(normalized_env(env, "MN_HOME") || Path.expand("~/.mn"), "model-remotes.json")
  end

  defp runtime_compose_env_path(env) do
    normalized_env(env, @runtime_compose_env_path_env) ||
      Path.join(normalized_env(env, "MN_HOME") || Path.expand("~/.mn"), "docker-compose.env")
  end

  defp upsert_runtime_model_ref(path, model_ref) do
    File.mkdir_p!(Path.dirname(path))
    existing = if File.regular?(path), do: File.read!(path), else: ""
    {lines, found?} = upsert_env_list_line(String.split(existing, "\n", trim: false), model_ref)
    lines = if found?, do: lines, else: lines ++ ["MN_NODE_RUNTIME_MODELS=#{model_ref}"]
    File.write!(path, lines |> trim_trailing_blank_lines() |> Enum.join("\n") |> Kernel.<>("\n"))
  end

  defp upsert_env_list_line(lines, model_ref) do
    Enum.map_reduce(lines, false, fn line, found? ->
      case String.split(line, "=", parts: 2) do
        ["MN_NODE_RUNTIME_MODELS", value] ->
          refs =
            value
            |> split_env_list()
            |> Kernel.++([model_ref])
            |> Enum.uniq_by(&String.downcase(&1))

          {"MN_NODE_RUNTIME_MODELS=#{Enum.join(refs, ",")}", true}

        _ ->
          {line, found?}
      end
    end)
  end

  defp trim_trailing_blank_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp read_model_remotes(path) do
    with true <- File.regular?(path),
         {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      remotes =
        case decoded do
          %{"remotes" => values} when is_map(values) -> Map.values(values)
          %{"remotes" => values} when is_list(values) -> values
          values when is_list(values) -> values
          _ -> []
        end

      Enum.filter(remotes, &is_map/1)
    else
      _ -> []
    end
  end

  defp remote_service_instance(remote, node_name, catalog) do
    model = normalized_remote_value(remote, "model")

    endpoint =
      normalized_remote_value(remote, "base_url") || normalized_remote_value(remote, "api_base")

    if model in [nil, ""] or endpoint in [nil, ""] do
      []
    else
      entry =
        case ModelCatalog.resolve(model, catalog) do
          {:ok, resolved} ->
            resolved

          {:error, _reason} ->
            %{
              "id" => model,
              "model" => model,
              "api_model" => normalized_remote_value(remote, "api_model") || model,
              "provider" => "docker_model_runner"
            }
        end

      api_model =
        normalized_remote_value(remote, "api_model") || Map.get(entry, "api_model") || model

      name = normalized_remote_value(remote, "name") || model
      service_node = normalized_remote_value(remote, "node") || to_string(node_name)

      service =
        entry
        |> ModelCatalog.service_instance(service_node)
        |> Map.put(
          "id",
          "#{service_node}:docker-model-runner:remote:#{ModelCatalog.normalize_tag(name)}"
        )
        |> Map.put("origin", "external")
        |> Map.put("address", endpoint)
        |> put_in(["meta", "api_model"], api_model)
        |> put_in(["meta", "api_base"], endpoint)
        |> put_in(["meta", "remote_name"], name)

      [service]
    end
  end

  defp normalized_remote_value(remote, key) do
    remote
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
          text -> String.trim_trailing(text, "/")
        end
    end
  end

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

  defp normalized_value(map, key) when is_map(map) do
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
