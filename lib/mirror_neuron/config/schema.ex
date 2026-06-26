defmodule MirrorNeuron.Config.Schema do
  @moduledoc false

  @default_temp_dir "/tmp/mirror_neuron"

  def specs do
    [
      spec("MN_ENV", :mn_env, :string, default: "dev"),
      spec("MN_HOME", :home, :path, default: {:home, ".mirrorneuron"}),
      spec("MN_LOG_LEVEL", :log_level, :string, default: "info"),
      spec("MN_CORE_HOST", :core_host, :string, default: "localhost"),
      spec("MN_API_HOST", :api_host, :string, default: "127.0.0.1"),
      spec("MN_API_PORT", :api_port, :integer, default: 8_000),
      spec("MN_GRPC_PORT", :grpc_port, :integer, default: 50_051),
      spec("MN_GRPC_AUTH_TOKEN", :grpc_auth_token, :secret),
      spec("MN_GRPC_ADMIN_TOKEN", :grpc_admin_token, :secret),
      spec("MN_GRPC_AUTH_TOKEN_FILE", :grpc_auth_token_file, :path),
      spec("MN_GRPC_ADMIN_TOKEN_FILE", :grpc_admin_token_file, :path),
      spec("MN_COOKIE", :cookie, :secret),
      spec("MN_REDIS_HOST", :redis_host, :string, default: "localhost"),
      spec("MN_REDIS_URL", :redis_url, :url, default: {:redis_url, "MN_REDIS_HOST"}),
      spec("MN_REDIS_NAMESPACE", :redis_namespace, :string, default: "mirror_neuron"),
      spec("MN_REDIS_HA_MODE", :redis_ha_mode, :string, default: "single"),
      spec("MN_REDIS_SENTINELS", :redis_sentinels, :string, default: ""),
      spec("MN_REDIS_SENTINEL_MASTER", :redis_sentinel_master, :string, default: "mirror-neuron"),
      spec("MN_REDIS_SENTINEL_HOST_MAP", :redis_sentinel_host_map, :string, default: ""),
      spec("MN_REDIS_DB", :redis_db, :integer, default: 0),
      spec("MN_REDIS_USERNAME", :redis_username, :secret),
      spec("MN_REDIS_PASSWORD", :redis_password, :secret),
      spec("MN_REDIS_SENTINEL_USERNAME", :redis_sentinel_username, :secret),
      spec("MN_REDIS_SENTINEL_PASSWORD", :redis_sentinel_password, :secret),
      spec("MN_REDIS_WAIT_REPLICAS", :redis_wait_replicas, :integer, default: 0),
      spec("MN_REDIS_WAIT_TIMEOUT_MS", :redis_wait_timeout_ms, :integer, default: 100),
      spec("MN_REDIS_RECONNECT_ATTEMPTS", :redis_reconnect_attempts, :integer, default: 10),
      spec("MN_REDIS_RECONNECT_BACKOFF_MS", :redis_reconnect_backoff_ms, :integer, default: 250),
      spec("MN_REDIS_RECONNECT_MAX_BACKOFF_MS", :redis_reconnect_max_backoff_ms, :integer,
        default: 2_000
      ),
      spec("MN_NETWORK_ONLY", :network_only, :boolean, default: false),
      spec("MN_NETWORK_JOIN_TOKEN", :network_join_token, :secret),
      spec("MN_NETWORK_ADVERTISE_HOST", :network_advertise_host, :string),
      spec("MN_NETWORK_REDIS_HOST", :network_redis_host, :string),
      spec("MN_NETWORK_REDIS_PORT", :network_redis_port, :integer),
      spec("MN_DIST_PORT", :dist_port, :integer, default: 4_370),
      spec("MN_CLUSTER_NODES", :cluster_nodes, :string, default: ""),
      spec("MN_NODE_ROLE", :node_role, :string, default: "runtime"),
      spec("MN_NODE_EXECUTION_PROFILES", :node_execution_profiles, :list, default: []),
      spec("MN_NODE_CAPABILITIES", :node_capabilities, :list, default: []),
      spec("MN_NODE_GPU", :node_gpu, :boolean),
      spec("MN_NODE_DISPLAY_NAME", :node_display_name, :string),
      spec("MN_NODE_GPU_COUNT", :node_gpu_count, :integer),
      spec("MN_NODE_CPU_MODEL", :node_cpu_model, :string),
      spec("MN_NODE_GPU_NAME", :node_gpu_name, :string),
      spec("MN_NODE_GPU_VENDOR", :node_gpu_vendor, :string),
      spec("MN_NODE_GPU_DRIVER", :node_gpu_driver, :string),
      spec("MN_NODE_GPU_TYPE", :node_gpu_type, :string),
      spec("MN_NODE_GPU_API_VERSION", :node_gpu_api_version, :string),
      spec("MN_NODE_GPU_DRIVER_VERSION", :node_gpu_driver_version, :string),
      spec("MN_NODE_HOST_PATHS", :node_host_paths, :list, default: []),
      spec("MN_NODE_RUNTIME_DRIVERS", :node_runtime_drivers, :list, default: []),
      spec("MN_EXECUTION_PROFILES_JSON", :execution_profiles, :json_map, default: %{}),
      spec("MN_MODEL_CATALOG_PATH", :model_catalog_path, :path),
      spec("MN_BUNDLES_DIR", :bundles_dir, :path),
      spec("MN_BUNDLE_CACHE_DIR", :bundle_cache_dir, :path),
      spec("MN_BUNDLE_ARCHIVE_MAX_BYTES", :bundle_archive_max_bytes, :integer),
      spec("MN_BUNDLE_RELOAD_MODE", :bundle_reload_mode, :string),
      spec("MN_BUNDLE_RELOAD_INTERVAL_SECONDS", :bundle_reload_interval_seconds, :integer),
      spec("MN_RECOVERY_EVAL_TTL_SECONDS", :recovery_eval_ttl_seconds, :integer, default: 86_400),
      spec("MN_JOB_LEASE_DURATION_MS", :job_lease_duration_ms, :integer, default: 60_000),
      spec("MN_JOB_LEASE_RENEW_INTERVAL_MS", :job_lease_renew_interval_ms, :integer,
        default: 10_000
      ),
      spec("MN_JOB_CALL_TIMEOUT_MS", :job_call_timeout_ms, :integer, default: 15_000),
      spec("MN_DELIVERY_RETRY_ATTEMPTS", :delivery_retry_attempts, :integer, default: 50),
      spec("MN_DELIVERY_RETRY_INTERVAL_MS", :delivery_retry_interval_ms, :integer, default: 50),
      spec("MN_RELIABILITY_STRATEGY", :reliability_strategy, :string, default: "auto"),
      spec("MN_CLUSTER_HEALTH_STABLE_MS", :cluster_health_stable_ms, :integer, default: 10_000),
      spec("MN_RELIABILITY_OBSERVER_INTERVAL_MS", :reliability_observer_interval_ms, :integer,
        default: 5_000
      ),
      spec("MN_NODE_RECONNECT_ATTEMPTS", :node_reconnect_attempts, :integer, default: 3),
      spec("MN_NODE_RECONNECT_BACKOFF_MS", :node_reconnect_backoff_ms, :integer, default: 1_000),
      spec("MN_OPENSHELL_BIN", :openshell_bin, :path, default: "openshell"),
      spec("MN_DOCKER_BIN", :docker_bin, :path, default: "docker"),
      spec("MN_DOCKER_WORKER_ENABLED", :docker_worker_enabled, :boolean),
      spec("MN_DOCKER_WORKER_NETWORK", :docker_worker_network, :string),
      spec("MN_DOCKER_WORKER_BUILDKIT", :docker_worker_buildkit, :boolean),
      spec("MN_BLUEPRINT_PYTHON_ENVS_DIR", :blueprint_python_envs_dir, :path),
      spec(
        "MN_BLUEPRINT_PYTHON_ENV_SETUP_TIMEOUT_MS",
        :blueprint_python_env_setup_timeout_ms,
        :integer, default: 600_000),
      spec("MN_SKILLS_ROOT", :skills_root, :path),
      spec("MN_WORKSPACE_ROOT", :workspace_root, :path),
      spec("MN_MAX_COMMAND_LENGTH", :max_command_length, :integer, default: 32_768),
      spec("MN_MAX_EVENT_BYTES", :max_event_bytes, :integer),
      spec("MN_MAX_ARTIFACT_BYTES", :max_artifact_bytes, :integer, default: 1_048_576),
      spec("MN_MAX_FAN_OUT", :max_fan_out, :integer),
      spec("MN_TEMP_DIR", :temp_dir, :path, default: @default_temp_dir),
      spec("MN_BLOB_STORE_ROOT", :blob_store_root, :path, default: {:home, ".mn/blobs"}),
      spec("MN_JOB_ARTIFACT_ROOT", :job_artifact_root, :path, default: {:job_artifact_root}),
      spec("MN_SHARED_STORAGE_ROOT", :shared_storage_root, :path, default: {:home, ".mn/shared"}),
      spec("MN_HOST_SHARED_STORAGE_ROOT", :host_shared_storage_root, :path),
      spec("MN_RUNTIME_SHARED_STORAGE_ROOT", :runtime_shared_storage_root, :path),
      spec("MN_RESOURCE_ADMISSION_ENABLED", :resource_admission_enabled, :boolean, default: true)
    ]
  end

  def app_env do
    excluded = MapSet.new([:mn_env, :home, :log_level, :api_host, :api_port])

    specs()
    |> Enum.reject(&MapSet.member?(excluded, &1.key))
    |> Enum.map(fn spec ->
      key =
        case spec.key do
          :runtime_shared_storage_root -> :shared_storage_root
          key -> key
        end

      {key, value!(spec)}
    end)
    |> Keyword.merge(shared_storage_root: shared_storage_root())
  end

  def spec_by_env(env_name) do
    Enum.find(specs(), &(&1.env == env_name))
  end

  def value!(%{env: "MN_REDIS_URL"} = spec), do: parse_value(spec, redis_url_default())

  def value!(%{env: "MN_JOB_ARTIFACT_ROOT"} = spec),
    do: parse_value(spec, job_artifact_root_default())

  def value!(%{env: "MN_RUNTIME_SHARED_STORAGE_ROOT"} = spec), do: parse_value(spec, nil)

  def value!(spec), do: parse_value(spec, default_value(Map.get(spec, :default)))

  def shared_storage_root do
    case System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT") do
      nil -> value!(spec_by_env("MN_SHARED_STORAGE_ROOT"))
      "" -> value!(spec_by_env("MN_SHARED_STORAGE_ROOT"))
      _value -> value!(spec_by_env("MN_RUNTIME_SHARED_STORAGE_ROOT"))
    end
  end

  def sensitive?(env_name) do
    case spec_by_env(env_name) do
      %{sensitive?: true} -> true
      _ -> false
    end
  end

  defp spec(env, key, type, opts \\ []) do
    %{
      env: env,
      key: key,
      type: type,
      default: Keyword.get(opts, :default),
      required?: Keyword.get(opts, :required, false),
      sensitive?: type == :secret or Keyword.get(opts, :sensitive, false)
    }
  end

  defp parse_value(spec, default) do
    raw = System.get_env(spec.env)

    cond do
      raw in [nil, ""] and spec.required? ->
        raise ArgumentError, "#{spec.env} is required"

      raw in [nil, ""] ->
        default

      true ->
        parse_type(raw, spec)
    end
  end

  defp parse_type(value, %{type: type, env: env}) do
    case type do
      :string -> value
      :secret -> value
      :path -> Path.expand(value)
      :integer -> parse_integer(value, env)
      :boolean -> parse_boolean(value, env)
      :list -> split_csv(value)
      :json_map -> parse_json_map(value, env)
      :url -> parse_url(value, env)
    end
  end

  defp parse_integer(value, env) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> raise ArgumentError, "#{env} must be an integer, got #{inspect(value)}"
    end
  end

  defp parse_boolean(value, env) do
    case String.downcase(value) do
      truthy when truthy in ["1", "true", "yes", "on"] -> true
      falsey when falsey in ["0", "false", "no", "off"] -> false
      _ -> raise ArgumentError, "#{env} must be a boolean, got #{inspect(value)}"
    end
  end

  defp parse_json_map(value, env) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> raise ArgumentError, "#{env} must be a JSON object"
    end
  end

  defp parse_url(value, env) do
    uri = URI.parse(value)

    if is_binary(uri.scheme) and is_binary(uri.host) do
      value
    else
      raise ArgumentError, "#{env} must be a valid URL"
    end
  end

  defp split_csv(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp default_value({:home, path}), do: Path.join(System.user_home!(), path) |> Path.expand()
  defp default_value(value), do: value

  defp redis_url_default do
    host = System.get_env("MN_REDIS_HOST", "localhost")
    "redis://#{host}:6379/0"
  end

  defp job_artifact_root_default do
    value!(spec_by_env("MN_BLOB_STORE_ROOT"))
    |> Path.expand()
    |> Path.dirname()
    |> Path.join("jobs")
  end
end
