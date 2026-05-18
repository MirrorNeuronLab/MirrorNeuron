defmodule MirrorNeuron.Config do
  @moduledoc false

  def fetch!(key), do: Application.fetch_env!(:mirror_neuron, key)

  def string(env_name, key), do: env_or_app(env_name, key) |> to_string()

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

  def env do
    System.get_env("MN_ENV", "dev")
  end

  def prod?, do: env() == "prod"

  def validate! do
    validate_mirror_neuron_env!()
    validate_port!("MN_GRPC_PORT", System.get_env("MN_GRPC_PORT", "50051"))
    validate_port!("MN_API_PORT", string("MN_API_PORT", :api_port))
    validate_redis_config!()
    validate_queue_limits!()
    validate_sandbox_limits!()
    validate_resource_admission!()
    validate_retention!()
    validate_runtime_efficiency!()
    validate_reliability!()
    validate_execution_profiles!()
    validate_production_secrets!()
    :ok
  end

  defp env_or_app(env_name, key) do
    case System.get_env(env_name) do
      nil -> fetch!(key)
      "" -> fetch!(key)
      value -> value
    end
  end

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
      raise ArgumentError, "MN_ENV must be one of dev, test, or prod"
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
      cookie = string("MN_COOKIE", :cookie)

      if cookie in ["", "mirrorneuron"] do
        raise ArgumentError,
              "MN_COOKIE must be set to a non-default secret when MN_ENV=prod"
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
    optional_positive_int!("MN_AGENT_PENDING_DRAIN_BATCH_SIZE")
    optional_positive_int!("MN_AGENT_SNAPSHOT_PENDING_LIMIT")
    optional_positive_int!("MN_LEASE_QUEUE_TIMEOUT_MS")
    optional_nonnegative_int!("MN_LEASE_MAX_QUEUE_LENGTH")
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

  defp validate_execution_profiles! do
    case System.get_env("MN_EXECUTION_PROFILES_JSON") do
      nil ->
        :ok

      "" ->
        :ok

      raw ->
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) ->
            :ok

          _ ->
            raise ArgumentError, "MN_EXECUTION_PROFILES_JSON must be a JSON object"
        end
    end
  end

  defp optional_positive_int!(env_name) do
    case System.get_env(env_name) do
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
    case System.get_env(env_name) do
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
    case System.get_env(env_name) do
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
    case System.get_env(env_name) do
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
