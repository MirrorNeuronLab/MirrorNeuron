defmodule MirrorNeuron.Runner.DockerWorker.Settings do
  @moduledoc "Runner names, executable settings and explicit scalar configuration."

  alias MirrorNeuron.Config

  def build_runner_name(config, opts) do
    [
      Map.get(config, "name"),
      Keyword.get(opts, :job_id),
      Keyword.get(opts, :agent_id),
      Keyword.get(opts, :attempt, 1),
      Keyword.get(opts, :invocation, 1)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&safe_name/1)
    |> Enum.join("-")
    |> case do
      "" -> "worker"
      value -> String.slice(value, 0, 96)
    end
  end

  def safe_name(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "-")
    |> String.trim("-")
  end

  def docker_bin(config) do
    Map.get(config, "docker_bin") ||
      get_in(config, ["docker", "bin"]) ||
      Config.optional_string("MN_DOCKER_BIN", :docker_bin) ||
      System.find_executable("docker") ||
      "docker"
  end

  def timeout_ms(config) do
    case Map.get(config, "timeout_seconds") do
      value when is_integer(value) and value > 0 -> value * 1000
      value when is_float(value) and value > 0 -> trunc(value * 1000)
      _ -> nil
    end
  end

  def max_output_bytes(config) do
    case Map.get(config, "max_output_bytes") do
      value when is_integer(value) and value > 0 -> value
      _ -> Config.integer("MN_MAX_ARTIFACT_BYTES", :max_artifact_bytes)
    end
  end

  def extra_env(config) do
    env =
      case Map.get(config, "environment") do
        env when is_map(env) ->
          Enum.into(env, %{}, fn {key, value} -> {to_string(key), to_string(value)} end)

        _ ->
          %{}
      end

    env =
      Map.merge(env, %{
        "MN_AGENT_BEACON_STDOUT_PREFIX" => "__MN_AGENT_BEACON__",
        "MN_AGENT_BEACON_INTERVAL_MS" => to_string(Map.get(config, "beacon_interval_ms", 15_000))
      })

    MirrorNeuron.Runtime.RunResourceEnvironment.for_container(config, env)
  end

  def truthy?(value) when value in [true, 1], do: true

  def truthy?(value) when is_binary(value),
    do: String.downcase(value) in ["1", "true", "yes", "on"]

  def truthy?(_value), do: false

  def nonempty?(value) when is_list(value), do: value != []

  def nonempty?(value) when is_map(value), do: map_size(value) > 0

  def nonempty?(_value), do: false
end
