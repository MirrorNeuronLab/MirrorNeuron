defmodule MirrorNeuron.Config do
  @moduledoc false

  def fetch!(key), do: Application.fetch_env!(:mirror_neuron, key)

  def string(env_name, key), do: env_or_app(env_name, key) |> to_string()

  def integer(env_name, key), do: parse_integer(env_or_app(env_name, key), env_name)

  def boolean(env_name, key), do: parse_boolean(env_or_app(env_name, key), env_name)

  def env do
    System.get_env("MIRROR_NEURON_ENV", "dev")
  end

  def prod?, do: env() == "prod"

  def validate! do
    validate_mirror_neuron_env!()
    validate_port!("MIRROR_NEURON_GRPC_PORT", System.get_env("MIRROR_NEURON_GRPC_PORT", "50051"))
    validate_port!("MIRROR_NEURON_API_PORT", string("MIRROR_NEURON_API_PORT", :api_port))
    validate_redis_url!()
    validate_queue_limits!()
    validate_sandbox_limits!()
    validate_resource_admission!()
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
      raise ArgumentError, "MIRROR_NEURON_ENV must be one of dev, test, or prod"
    end
  end

  defp validate_port!(env_name, value) do
    port = parse_integer(value, env_name)

    unless port in 1..65_535 do
      raise ArgumentError, "#{env_name} must be between 1 and 65535"
    end
  end

  defp validate_redis_url! do
    url = string("MIRROR_NEURON_REDIS_URL", :redis_url)
    uri = URI.parse(url)

    unless uri.scheme in ["redis", "rediss"] and is_binary(uri.host) do
      raise ArgumentError, "MIRROR_NEURON_REDIS_URL must be a valid redis:// or rediss:// URL"
    end
  end

  defp validate_queue_limits! do
    max_depth = optional_positive_int!("MIRROR_NEURON_DEFAULT_MAX_AGENT_QUEUE_DEPTH")
    high = optional_positive_int!("MIRROR_NEURON_DEFAULT_AGENT_QUEUE_HIGH_WATERMARK")
    low = optional_nonnegative_int!("MIRROR_NEURON_DEFAULT_AGENT_QUEUE_LOW_WATERMARK")

    if max_depth && high && high > max_depth do
      raise ArgumentError,
            "MIRROR_NEURON_DEFAULT_AGENT_QUEUE_HIGH_WATERMARK must be <= MIRROR_NEURON_DEFAULT_MAX_AGENT_QUEUE_DEPTH"
    end

    if high && low && low > high do
      raise ArgumentError,
            "MIRROR_NEURON_DEFAULT_AGENT_QUEUE_LOW_WATERMARK must be <= MIRROR_NEURON_DEFAULT_AGENT_QUEUE_HIGH_WATERMARK"
    end
  end

  defp validate_production_secrets! do
    if prod?() do
      cookie = string("MIRROR_NEURON_COOKIE", :cookie)

      if cookie in ["", "mirrorneuron"] do
        raise ArgumentError,
              "MIRROR_NEURON_COOKIE must be set to a non-default secret when MIRROR_NEURON_ENV=prod"
      end
    end
  end

  defp validate_sandbox_limits! do
    optional_positive_int!("MIRROR_NEURON_MAX_COMMAND_LENGTH")
    optional_positive_int!("MIRROR_NEURON_MAX_EVENT_BYTES")
    optional_positive_int!("MIRROR_NEURON_MAX_ARTIFACT_BYTES")
    optional_positive_int!("MIRROR_NEURON_MAX_FAN_OUT")
  end

  defp validate_resource_admission! do
    optional_positive_float!("MIRROR_NEURON_MAX_CPU_LOAD_RATIO")
    optional_ratio!("MIRROR_NEURON_MAX_MEMORY_USED_RATIO")
    optional_ratio!("MIRROR_NEURON_MAX_GPU_UTILIZATION_RATIO")
    optional_ratio!("MIRROR_NEURON_MAX_GPU_MEMORY_USED_RATIO")
    boolean("MIRROR_NEURON_RESOURCE_ADMISSION_ENABLED", :resource_admission_enabled)
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
