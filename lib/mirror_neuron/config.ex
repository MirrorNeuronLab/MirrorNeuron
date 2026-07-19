defmodule MirrorNeuron.Config do
  @moduledoc false

  alias MirrorNeuron.Config.EnvFile
  alias MirrorNeuron.Config.Schema

  def fetch!(key), do: Application.fetch_env!(:mirror_neuron, key)

  def load_env_files!(root \\ File.cwd!()) do
    real_env = System.get_env()
    selected_env = real_env |> Map.get("MN_ENV") |> normalize_env()

    protected_keys =
      real_env
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.put("MN_ENV")

    System.put_env("MN_ENV", selected_env)

    loaded =
      [
        EnvFile.load_file(Path.join(root, ".env"), protected_keys),
        EnvFile.load_file(
          Path.join(root, ".env.#{env_file_suffix(selected_env)}"),
          protected_keys
        )
      ]
      |> Enum.flat_map(fn
        {:ok, path} -> [path]
        :missing -> []
      end)

    %{env: selected_env, loaded_files: loaded}
  end

  def app_env! do
    Schema.app_env()
  end

  def string(env_name, key), do: env_or_app(env_name, key) |> to_string()

  def optional_string(env_name, key) do
    case env_or_app(env_name, key, nil) do
      nil -> nil
      "" -> nil
      value -> to_string(value)
    end
  end

  def secret(env_name, key), do: optional_string(env_name, key)

  def secret(env_name, key, file_env_name, file_key) do
    case secret(env_name, key) do
      nil -> secret_file(file_env_name, file_key)
      "" -> secret_file(file_env_name, file_key)
      value -> value
    end
  end

  def executable(env_name, key) do
    configured = string(env_name, key)

    cond do
      Path.type(configured) == :absolute or String.contains?(configured, "/") ->
        configured

      resolved = System.find_executable(configured) ->
        resolved

      resolved = find_in_common_user_bins(configured) ->
        resolved

      true ->
        configured
    end
  end

  def integer(env_name, key), do: parse_integer(env_or_app(env_name, key), env_name)

  def boolean(env_name, key), do: parse_boolean(env_or_app(env_name, key), env_name)

  def list(env_name, key) do
    case env_or_app(env_name, key, []) do
      value when is_list(value) ->
        Enum.map(value, &to_string/1)

      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value ->
        raise ArgumentError, "#{env_name} must be a comma-separated list, got #{inspect(value)}"
    end
  end

  def env do
    System.get_env("MN_ENV")
    |> normalize_env()
  end

  def prod?, do: env() == "prod"

  def validate! do
    validate_mirror_neuron_env!()
    validate_port!("MN_GRPC_PORT", integer("MN_GRPC_PORT", :grpc_port))
    validate_redis_config!()
    validate_queue_limits!()
    validate_sandbox_limits!()
    validate_resource_admission!()
    validate_retention!()
    validate_runtime_efficiency!()
    validate_reliability!()
    validate_execution_profiles!()
    validate_shared_storage!()
    validate_network_config!()
    validate_grpc_tokens!()
    validate_production_secrets!()
    :ok
  end

  defp env_or_app(env_name, key, default \\ :raise) do
    case System.get_env(env_name) do
      nil -> app_value(key, default)
      "" -> app_value(key, default)
      value -> value
    end
  end

  defp app_value(key, :raise), do: fetch!(key)
  defp app_value(key, default), do: Application.get_env(:mirror_neuron, key, default)

  defp find_in_common_user_bins(executable) do
    user_home = System.get_env("HOME") || System.user_home()

    [
      user_home && Path.join([user_home, ".local", "bin"]),
      "/opt/homebrew/bin",
      "/usr/local/bin"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.join(&1, executable))
    |> Enum.find(&File.regular?/1)
  end

  defp parse_integer(value, _env_name) when is_integer(value), do: value

  defp parse_integer(value, env_name) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        integer

      _ ->
        raise ArgumentError, "#{env_name} must be an integer, got #{inspect(value)}"
    end
  end

  defp parse_integer(value, env_name),
    do: raise(ArgumentError, "#{env_name} must be an integer, got #{inspect(value)}")

  defp parse_boolean(value, _env_name) when is_boolean(value), do: value

  defp parse_boolean(value, env_name) when is_binary(value) do
    case String.downcase(value) do
      truthy when truthy in ["1", "true", "yes", "on"] ->
        true

      falsey when falsey in ["0", "false", "no", "off"] ->
        false

      _ ->
        raise ArgumentError, "#{env_name} must be a boolean, got #{inspect(value)}"
    end
  end

  defp parse_boolean(value, env_name),
    do: raise(ArgumentError, "#{env_name} must be a boolean, got #{inspect(value)}")

  defp validate_mirror_neuron_env! do
    unless env() in ["dev", "test", "prod"] do
      raise ArgumentError, "MN_ENV must be one of dev, development, test, prod, or production"
    end
  end

  defp validate_port!(env_name, value) do
    port = parse_integer(value, env_name)

    unless port in 1..65_535 do
      raise ArgumentError, "#{env_name} must be between 1 and 65535"
    end
  end

  defp validate_redis_config! do
    case redis_ha_mode() do
      "single" ->
        validate_redis_url!()

      "sentinel" ->
        validate_redis_sentinel!()

      other ->
        raise ArgumentError,
              "MN_REDIS_HA_MODE must be one of single or sentinel, got #{inspect(other)}"
    end

    validate_redis_wait!()
  end

  defp redis_ha_mode do
    "MN_REDIS_HA_MODE"
    |> string(:redis_ha_mode)
    |> String.downcase()
  end

  defp validate_redis_url! do
    url = string("MN_REDIS_URL", :redis_url)
    uri = URI.parse(url)

    unless uri.scheme in ["redis", "rediss"] and is_binary(uri.host) do
      raise ArgumentError, "MN_REDIS_URL must be a valid redis:// or rediss:// URL"
    end
  end

  defp validate_redis_sentinel! do
    sentinels = string("MN_REDIS_SENTINELS", :redis_sentinels)

    if MirrorNeuron.Redis.Sentinel.parse_sentinels(sentinels) == [] do
      raise ArgumentError,
            "MN_REDIS_SENTINELS must contain at least one host:port when MN_REDIS_HA_MODE=sentinel"
    end

    if String.trim(string("MN_REDIS_SENTINEL_MASTER", :redis_sentinel_master)) == "" do
      raise ArgumentError, "MN_REDIS_SENTINEL_MASTER must not be empty"
    end

    db = integer("MN_REDIS_DB", :redis_db)

    if db < 0 do
      raise ArgumentError, "MN_REDIS_DB must be greater than or equal to 0"
    end
  end

  defp validate_redis_wait! do
    wait_replicas = integer("MN_REDIS_WAIT_REPLICAS", :redis_wait_replicas)
    wait_timeout_ms = integer("MN_REDIS_WAIT_TIMEOUT_MS", :redis_wait_timeout_ms)

    if wait_replicas < 0 do
      raise ArgumentError, "MN_REDIS_WAIT_REPLICAS must be greater than or equal to 0"
    end

    if wait_timeout_ms < 0 do
      raise ArgumentError,
            "MN_REDIS_WAIT_TIMEOUT_MS must be greater than or equal to 0"
    end

    optional_positive_int!("MN_REDIS_RECONNECT_ATTEMPTS")
    optional_positive_int!("MN_REDIS_RECONNECT_BACKOFF_MS")
    optional_positive_int!("MN_REDIS_RECONNECT_MAX_BACKOFF_MS")
    optional_positive_int!("MN_NODE_RECONNECT_ATTEMPTS")
    optional_positive_int!("MN_NODE_RECONNECT_BACKOFF_MS")
  end

  defp validate_queue_limits! do
    max_depth = optional_positive_int!("MN_DEFAULT_MAX_AGENT_QUEUE_DEPTH")
    high = optional_positive_int!("MN_DEFAULT_AGENT_QUEUE_HIGH_WATERMARK")
    low = optional_nonnegative_int!("MN_DEFAULT_AGENT_QUEUE_LOW_WATERMARK")

    if max_depth && high && high > max_depth do
      raise ArgumentError,
            "MN_DEFAULT_AGENT_QUEUE_HIGH_WATERMARK must be <= MN_DEFAULT_MAX_AGENT_QUEUE_DEPTH"
    end

    if high && low && low > high do
      raise ArgumentError,
            "MN_DEFAULT_AGENT_QUEUE_LOW_WATERMARK must be <= MN_DEFAULT_AGENT_QUEUE_HIGH_WATERMARK"
    end
  end

  defp validate_production_secrets! do
    if prod?() do
      cookie = secret("MN_COOKIE", :cookie)

      if cookie == "mirrorneuron" do
        raise ArgumentError,
              "MN_COOKIE must not use the legacy default secret when MN_ENV=prod"
      end
    end
  end

  defp validate_network_config! do
    if boolean("MN_NETWORK_ONLY", :network_only) and
         blank?(secret("MN_NETWORK_JOIN_TOKEN", :network_join_token)) do
      raise ArgumentError, "MN_NETWORK_JOIN_TOKEN is required when MN_NETWORK_ONLY=true"
    end
  end

  defp validate_grpc_tokens! do
    if prod?() do
      if blank?(
           secret(
             "MN_GRPC_AUTH_TOKEN",
             :grpc_auth_token,
             "MN_GRPC_AUTH_TOKEN_FILE",
             :grpc_auth_token_file
           )
         ) do
        raise ArgumentError, "MN_GRPC_AUTH_TOKEN is required when MN_ENV=prod"
      end
    end
  end

  defp validate_sandbox_limits! do
    optional_positive_int!("MN_MAX_COMMAND_LENGTH")
    optional_positive_int!("MN_MAX_EVENT_BYTES")
    optional_positive_int!("MN_MAX_ARTIFACT_BYTES")
    optional_positive_int!("MN_MAX_FAN_OUT")
  end

  defp validate_resource_admission! do
    optional_positive_float!("MN_MAX_CPU_LOAD_RATIO")
    optional_ratio!("MN_MAX_MEMORY_USED_RATIO")
    optional_ratio!("MN_MAX_GPU_UTILIZATION_RATIO")
    optional_ratio!("MN_MAX_GPU_MEMORY_USED_RATIO")
    boolean("MN_RESOURCE_ADMISSION_ENABLED", :resource_admission_enabled)
  end

  defp validate_retention! do
    optional_nonnegative_int!("MN_TERMINAL_JOB_TTL_SECONDS")
    optional_nonnegative_int!("MN_EVENT_TTL_SECONDS")
    optional_nonnegative_int!("MN_EVENT_MAX_COUNT")
    optional_nonnegative_int!("MN_AGENT_SNAPSHOT_TTL_SECONDS")
    optional_nonnegative_int!("MN_RETENTION_GC_INTERVAL_MS")
  end

  defp validate_runtime_efficiency! do
    optional_positive_int!("MN_AGENT_SNAPSHOT_PENDING_LIMIT")
    optional_positive_int!("MN_LEASE_QUEUE_TIMEOUT_MS")
    optional_nonnegative_int!("MN_LEASE_MAX_QUEUE_LENGTH")
    optional_positive_int!("MN_JOB_CALL_TIMEOUT_MS")
    optional_positive_int!("MN_CANCEL_JOB_CALL_TIMEOUT_MS")
    optional_nonnegative_int!("MN_JOB_SNAPSHOT_INTERVAL_MS")
    optional_positive_int!("MN_MESSAGE_DEFAULT_TTL_SECONDS")
    optional_positive_int!("MN_MESSAGE_MAX_TTL_SECONDS")
    optional_positive_int!("MN_MESSAGE_ACK_RECEIPT_TTL_SECONDS")
    optional_positive_int!("MN_MESSAGE_STREAM_TTL_SECONDS")
    optional_positive_int!("MN_MESSAGE_MAX_PENDING_PER_AGENT")
    optional_positive_int!("MN_MESSAGE_MAX_PENDING_PER_JOB")
    optional_positive_int!("MN_MESSAGE_ACK_TIMEOUT_MS")
    optional_positive_int!("MN_MESSAGE_LEASE_RENEW_MS")
    optional_positive_int!("MN_MESSAGE_DELIVERY_MAX_ATTEMPTS")
    optional_positive_int!("MN_MESSAGE_DELIVERY_POLL_MS")

    default_ttl = integer("MN_MESSAGE_DEFAULT_TTL_SECONDS", :message_default_ttl_seconds)
    max_ttl = integer("MN_MESSAGE_MAX_TTL_SECONDS", :message_max_ttl_seconds)

    if default_ttl > max_ttl do
      raise ArgumentError,
            "MN_MESSAGE_DEFAULT_TTL_SECONDS must not exceed MN_MESSAGE_MAX_TTL_SECONDS"
    end

    ack_timeout = integer("MN_MESSAGE_ACK_TIMEOUT_MS", :message_ack_timeout_ms)
    lease_renew = integer("MN_MESSAGE_LEASE_RENEW_MS", :message_lease_renew_ms)

    if lease_renew >= ack_timeout do
      raise ArgumentError, "MN_MESSAGE_LEASE_RENEW_MS must be less than MN_MESSAGE_ACK_TIMEOUT_MS"
    end
  end

  defp validate_reliability! do
    strategy =
      "MN_RELIABILITY_STRATEGY"
      |> string(:reliability_strategy)
      |> String.downcase()

    unless strategy == "auto" do
      raise ArgumentError, "MN_RELIABILITY_STRATEGY must be auto"
    end

    optional_nonnegative_int!("MN_CLUSTER_HEALTH_STABLE_MS")
    optional_positive_int!("MN_RELIABILITY_OBSERVER_INTERVAL_MS")
  end

  defp validate_shared_storage! do
    MirrorNeuron.Artifacts.SharedStorage.validate!()
  end

  defp validate_execution_profiles! do
    "MN_EXECUTION_PROFILES_JSON"
    |> env_or_app(:execution_profiles, nil)
    |> validate_execution_profiles_value!()
  end

  defp optional_positive_int!(env_name) do
    case optional_raw(env_name) do
      nil ->
        nil

      value ->
        parsed = parse_integer(value, env_name)

        unless parsed > 0 do
          raise ArgumentError, "#{env_name} must be greater than 0"
        end

        parsed
    end
  end

  defp optional_nonnegative_int!(env_name) do
    case optional_raw(env_name) do
      nil ->
        nil

      value ->
        parsed = parse_integer(value, env_name)

        unless parsed >= 0 do
          raise ArgumentError, "#{env_name} must be greater than or equal to 0"
        end

        parsed
    end
  end

  defp optional_positive_float!(env_name) do
    case optional_raw(env_name) do
      nil ->
        nil

      value ->
        parsed = parse_float(value, env_name)

        unless parsed > 0 do
          raise ArgumentError, "#{env_name} must be greater than 0"
        end

        parsed
    end
  end

  defp optional_ratio!(env_name) do
    case optional_raw(env_name) do
      nil ->
        nil

      value ->
        parsed = parse_float(value, env_name)

        unless parsed > 0 and parsed <= 1 do
          raise ArgumentError, "#{env_name} must be greater than 0 and less than or equal to 1"
        end

        parsed
    end
  end

  defp optional_raw(env_name) do
    case System.get_env(env_name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp secret_file(env_name, key) do
    case optional_string(env_name, key) do
      nil ->
        nil

      path ->
        case File.read(path) do
          {:ok, value} ->
            String.trim(value)

          {:error, reason} ->
            raise ArgumentError, "#{env_name} could not be read: #{:file.format_error(reason)}"
        end
    end
  end

  defp validate_execution_profiles_value!(nil), do: :ok
  defp validate_execution_profiles_value!(""), do: :ok
  defp validate_execution_profiles_value!(value) when is_map(value), do: :ok

  defp validate_execution_profiles_value!(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) ->
        :ok

      _ ->
        raise ArgumentError, "MN_EXECUTION_PROFILES_JSON must be a JSON object"
    end
  end

  defp validate_execution_profiles_value!(_raw) do
    raise ArgumentError, "MN_EXECUTION_PROFILES_JSON must be a JSON object"
  end

  defp normalize_env(nil), do: "dev"
  defp normalize_env(""), do: "dev"
  defp normalize_env("development"), do: "dev"
  defp normalize_env("production"), do: "prod"
  defp normalize_env(value), do: value

  defp env_file_suffix("prod"), do: "prod"
  defp env_file_suffix(env), do: env

  defp blank?(value), do: value in [nil, ""]

  defp parse_float(value, _env_name) when is_float(value), do: value
  defp parse_float(value, _env_name) when is_integer(value), do: value / 1

  defp parse_float(value, env_name) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} ->
        float

      _ ->
        raise ArgumentError, "#{env_name} must be a number, got #{inspect(value)}"
    end
  end

  defp parse_float(value, env_name),
    do: raise(ArgumentError, "#{env_name} must be a number, got #{inspect(value)}")
end
