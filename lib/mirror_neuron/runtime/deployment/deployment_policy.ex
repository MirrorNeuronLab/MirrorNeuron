defmodule MirrorNeuron.Runtime.DeploymentPolicy do
  @moduledoc false

  alias MirrorNeuron.Manifest

  @strategies ["rolling", "canary", "blue-green"]
  @health_checks ["checks", "agent_states"]

  @defaults %{
    "strategy" => "rolling",
    "max_parallel" => 1,
    "canary" => 0,
    "min_healthy_ms" => 10_000,
    "healthy_deadline_ms" => 300_000,
    "progress_deadline_ms" => 600_000,
    "health_check" => "checks",
    "auto_promote" => false,
    "auto_revert" => false
  }

  def normalize(%Manifest{} = manifest, overrides) do
    manifest
    |> manifest_policy()
    |> Map.merge(stringify_map(overrides || %{}))
    |> normalize()
  end

  def normalize(policy) when is_map(policy) do
    policy = stringify_map(policy)

    @defaults
    |> Map.merge(policy)
    |> Map.update!("strategy", &normalize_strategy/1)
    |> Map.update!("health_check", &normalize_health_check/1)
    |> put_integer("max_parallel", 1)
    |> put_integer("canary", 0)
    |> put_integer("min_healthy_ms", 10_000)
    |> put_integer("healthy_deadline_ms", 300_000)
    |> put_integer("progress_deadline_ms", 600_000)
    |> put_boolean("auto_promote", false)
    |> put_boolean("auto_revert", false)
  end

  def normalize(_policy), do: @defaults

  def deployment_key(%Manifest{} = manifest, override \\ nil) do
    cond do
      present?(override) ->
        to_string(override)

      present?(get_in(manifest.metadata || %{}, ["deployment_key"])) ->
        to_string(get_in(manifest.metadata, ["deployment_key"]))

      present?(get_in(manifest.deployment || %{}, ["key"])) ->
        to_string(get_in(manifest.deployment, ["key"]))

      present?(get_in(manifest.policies || %{}, ["deployment_key"])) ->
        to_string(get_in(manifest.policies, ["deployment_key"]))

      present?(manifest.job_name) ->
        to_string(manifest.job_name)

      true ->
        to_string(manifest.graph_id)
    end
  end

  def validate_manifest(%Manifest{} = manifest) do
    []
    |> validate_deployment(manifest.deployment || %{}, "deployment")
    |> validate_update_policy(manifest_policy(manifest), "policies.update")
    |> Enum.reverse()
  end

  def supported_strategies, do: @strategies

  defp manifest_policy(%Manifest{policies: policies}) when is_map(policies) do
    Map.get(policies, "update") || Map.get(policies, :update) || %{}
  end

  defp manifest_policy(_manifest), do: %{}

  defp validate_deployment(errors, deployment, _path) when deployment in [%{}, nil], do: errors

  defp validate_deployment(errors, deployment, path) when is_map(deployment) do
    key = map_get(deployment, "key")

    errors
    |> maybe_error(not is_nil(key) and not valid_key?(key), "#{path}.key must be a string")
  end

  defp validate_deployment(errors, _deployment, path), do: ["#{path} must be an object" | errors]

  defp validate_update_policy(errors, policy, _path) when policy in [%{}, nil], do: errors

  defp validate_update_policy(errors, policy, path) when is_map(policy) do
    errors
    |> validate_in(policy, path, "strategy", @strategies)
    |> validate_in(policy, path, "health_check", @health_checks)
    |> validate_nonnegative_integer(policy, path, "max_parallel")
    |> validate_nonnegative_integer(policy, path, "canary")
    |> validate_nonnegative_integer(policy, path, "min_healthy_ms")
    |> validate_positive_integer(policy, path, "healthy_deadline_ms")
    |> validate_nonnegative_integer(policy, path, "progress_deadline_ms")
    |> validate_boolean(policy, path, "auto_promote")
    |> validate_boolean(policy, path, "auto_revert")
    |> validate_auto_promote_canary(policy, path)
  end

  defp validate_update_policy(errors, _policy, path), do: ["#{path} must be an object" | errors]

  defp validate_auto_promote_canary(errors, policy, path) do
    auto_promote = map_get(policy, "auto_promote")
    canary = map_get(policy, "canary")
    strategy = map_get(policy, "strategy")

    if auto_promote == true and normalize_strategy(strategy) == "canary" and
         integer_value(canary, 0) <= 0 do
      ["#{path}.auto_promote requires canary > 0 for canary deployments" | errors]
    else
      errors
    end
  end

  defp validate_nonnegative_integer(errors, policy, path, key) do
    case map_get(policy, key) do
      nil -> errors
      value when is_integer(value) and value >= 0 -> errors
      _ -> ["#{path}.#{key} must be a non-negative integer" | errors]
    end
  end

  defp validate_positive_integer(errors, policy, path, key) do
    case map_get(policy, key) do
      nil -> errors
      value when is_integer(value) and value > 0 -> errors
      _ -> ["#{path}.#{key} must be a positive integer" | errors]
    end
  end

  defp validate_boolean(errors, policy, path, key) do
    case map_get(policy, key) do
      nil -> errors
      value when is_boolean(value) -> errors
      _ -> ["#{path}.#{key} must be a boolean" | errors]
    end
  end

  defp validate_in(errors, policy, path, key, supported) do
    case map_get(policy, key) do
      nil ->
        errors

      value when is_binary(value) ->
        if String.downcase(value) in supported do
          errors
        else
          ["#{path}.#{key} has unsupported value #{inspect(value)}" | errors]
        end

      value ->
        ["#{path}.#{key} has unsupported value #{inspect(value)}" | errors]
    end
  end

  defp normalize_strategy(value) when is_binary(value) do
    value = value |> String.downcase() |> String.replace("_", "-")
    if value in @strategies, do: value, else: "rolling"
  end

  defp normalize_strategy(_value), do: "rolling"

  defp normalize_health_check(value) when is_binary(value) do
    value = value |> String.downcase() |> String.replace("-", "_")
    if value in @health_checks, do: value, else: "checks"
  end

  defp normalize_health_check(_value), do: "checks"

  defp put_integer(policy, key, default) do
    Map.put(policy, key, integer_value(Map.get(policy, key), default))
  end

  defp put_boolean(policy, key, default) do
    Map.put(policy, key, boolean_value(Map.get(policy, key), default))
  end

  defp integer_value(value, _default) when is_integer(value) and value >= 0, do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default

  defp boolean_value(value, _default) when is_boolean(value), do: value

  defp boolean_value(value, default) when is_binary(value) do
    case String.downcase(value) do
      value when value in ["1", "true", "yes", "on"] -> true
      value when value in ["0", "false", "no", "off"] -> false
      _ -> default
    end
  end

  defp boolean_value(_value, default), do: default

  defp map_get(map, key) when is_map(map) do
    string_key = to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp map_get(_map, _key), do: nil

  defp valid_key?(value), do: is_binary(value) and String.trim(value) != ""
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
