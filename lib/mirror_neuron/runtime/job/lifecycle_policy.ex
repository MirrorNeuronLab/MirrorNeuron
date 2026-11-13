defmodule MirrorNeuron.Runtime.LifecyclePolicy do
  @moduledoc false

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime

  @restart_modes ["fail", "delay"]
  @delay_functions ["constant", "exponential", "fibonacci"]

  @service_restart_interval_ms 600_000
  @batch_restart_interval_ms 86_400_000
  @restart_delay_ms 1_000
  @restart_max_delay_ms 30_000
  @reschedule_service_delay_ms 5_000
  @reschedule_service_max_delay_ms 300_000
  @reschedule_batch_delay_ms 5_000

  def normalize(%Manifest{} = manifest, job_type, recovery_policy, agent_id \\ nil) do
    %{
      "restart_policy" => restart_policy(manifest, job_type, recovery_policy, agent_id),
      "reschedule_policy" => reschedule_policy(manifest, job_type, recovery_policy, agent_id)
    }
  end

  def restart_policy(%Manifest{} = manifest, job_type, recovery_policy, agent_id \\ nil) do
    job_type = normalize_job_type(job_type)
    recovery_policy = normalize_recovery_policy(recovery_policy)

    defaults = restart_defaults(job_type, recovery_policy)

    defaults
    |> merge_policy(policy_map(manifest.policies, "restart"))
    |> merge_policy(agent_policy(manifest, agent_id, "restart"))
    |> normalize_restart_policy(job_type, recovery_policy)
  end

  def reschedule_policy(%Manifest{} = manifest, job_type, recovery_policy, agent_id \\ nil) do
    job_type = normalize_job_type(job_type)
    recovery_policy = normalize_recovery_policy(recovery_policy)

    reschedule_defaults(job_type, recovery_policy)
    |> merge_policy(policy_map(manifest.policies, "reschedule"))
    |> merge_policy(agent_policy(manifest, agent_id, "reschedule"))
    |> normalize_reschedule_policy(job_type, recovery_policy)
  end

  def restart_policy_from_job(job, agent_id \\ nil) when is_map(job) do
    with {:ok, manifest} <- manifest_from_job(job) do
      restart_policy(
        manifest,
        job_type(job),
        recovery_policy(job),
        source_agent_id(job, agent_id)
      )
    else
      _ ->
        Map.get(job, "restart_policy") ||
          restart_defaults(job_type(job), recovery_policy(job))
    end
  end

  def reschedule_policy_from_job(job, agent_id \\ nil) when is_map(job) do
    with {:ok, manifest} <- manifest_from_job(job) do
      reschedule_policy(
        manifest,
        job_type(job),
        recovery_policy(job),
        source_agent_id(job, agent_id)
      )
    else
      _ ->
        Map.get(job, "reschedule_policy") ||
          reschedule_defaults(job_type(job), recovery_policy(job))
    end
  end

  def validate_manifest(%Manifest{} = manifest) do
    []
    |> validate_policy_container(manifest.policies || %{}, "policies")
    |> validate_node_policies(manifest.nodes)
    |> Enum.reverse()
  end

  def validate_policy_container(errors, policies, path) when is_map(policies) do
    errors
    |> validate_restart_policy(policy_map(policies, "restart"), "#{path}.restart")
    |> validate_reschedule_policy(policy_map(policies, "reschedule"), "#{path}.reschedule")
  end

  def validate_policy_container(errors, policies, path) when is_nil(policies) do
    validate_policy_container(errors, %{}, path)
  end

  def validate_policy_container(errors, _policies, path),
    do: ["#{path} must be an object" | errors]

  def attempt_decision(policy, history, now \\ DateTime.utc_now()) do
    policy = normalize_policy(policy)
    history = active_history(policy, history, now)
    attempts = integer_value(policy["attempts"], 0)
    unlimited? = policy["unlimited"] == true

    cond do
      policy["enabled"] == false ->
        {:exhausted,
         %{
           "reason" => "#{policy["type"] || "lifecycle"} policy is disabled",
           "attempts" => length(history),
           "wait_until" => nil,
           "wait_ms" => nil
         }}

      unlimited? or length(history) < attempts ->
        attempt = length(history) + 1

        {:allowed,
         %{
           "attempt" => attempt,
           "delay_ms" => delay_ms(policy, attempt),
           "attempts_remaining" => if(unlimited?, do: nil, else: max(attempts - attempt, 0))
         }}

      true ->
        wait_until = window_reset_at(policy, history)

        {:exhausted,
         %{
           "reason" => "#{policy["type"] || "lifecycle"} attempts exhausted",
           "attempts" => length(history),
           "wait_until" => wait_until && DateTime.to_iso8601(wait_until),
           "wait_ms" => wait_until && max(DateTime.diff(wait_until, now, :millisecond), 0)
         }}
    end
  end

  def append_history(history, action, reason, now \\ Runtime.timestamp()) do
    entry = %{
      "action" => to_string(action),
      "reason" => stringify(reason),
      "at" => timestamp(now)
    }

    history
    |> List.wrap()
    |> Kernel.++([entry])
    |> Enum.take(-50)
  end

  def active_attempt_count(policy, history, now \\ DateTime.utc_now()) do
    policy
    |> normalize_policy()
    |> active_history(history, now)
    |> length()
  end

  def delay_ms(policy, attempt) do
    policy = normalize_policy(policy)
    base = integer_value(policy["delay_ms"], 0)
    max_delay = integer_value(policy["max_delay_ms"], base)

    computed =
      case policy["delay_function"] do
        "exponential" -> round(base * :math.pow(2, max(attempt - 1, 0)))
        "fibonacci" -> base * fibonacci(attempt)
        _constant -> base
      end

    min(computed, max_delay)
  end

  def iso_after(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(delay_ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  def normalize_job_type(nil), do: "batch"

  def normalize_job_type(value) do
    value
    |> to_string()
    |> String.downcase()
    |> case do
      type when type in ["service", "batch", "system", "sysbatch"] -> type
      _ -> "batch"
    end
  end

  def normalize_recovery_policy(nil), do: "local_restart"
  def normalize_recovery_policy(value), do: to_string(value)

  def supported_restart_modes, do: @restart_modes
  def supported_delay_functions, do: @delay_functions

  defp restart_defaults(_job_type, "manual_recover") do
    %{
      "type" => "restart",
      "enabled" => false,
      "attempts" => 0,
      "interval_ms" => @batch_restart_interval_ms,
      "delay_ms" => @restart_delay_ms,
      "delay_function" => "exponential",
      "max_delay_ms" => @restart_max_delay_ms,
      "mode" => "fail"
    }
  end

  defp restart_defaults(job_type, recovery_policy)
       when job_type in ["service", "system"] do
    %{
      "type" => "restart",
      "enabled" => true,
      "attempts" => 3,
      "interval_ms" => @service_restart_interval_ms,
      "delay_ms" => @restart_delay_ms,
      "delay_function" => "exponential",
      "max_delay_ms" => @restart_max_delay_ms,
      "mode" => if(recovery_policy == "cluster_recover", do: "fail", else: "delay")
    }
  end

  defp restart_defaults(_job_type, _recovery_policy) do
    %{
      "type" => "restart",
      "enabled" => true,
      "attempts" => 3,
      "interval_ms" => @batch_restart_interval_ms,
      "delay_ms" => @restart_delay_ms,
      "delay_function" => "exponential",
      "max_delay_ms" => @restart_max_delay_ms,
      "mode" => "fail"
    }
  end

  defp reschedule_defaults(_job_type, "manual_recover") do
    %{
      "type" => "reschedule",
      "enabled" => false,
      "attempts" => 0,
      "interval_ms" => @batch_restart_interval_ms,
      "delay_ms" => @reschedule_batch_delay_ms,
      "delay_function" => "constant",
      "max_delay_ms" => @reschedule_batch_delay_ms,
      "unlimited" => false
    }
  end

  defp reschedule_defaults(job_type, "cluster_recover") when job_type in ["service", "system"] do
    %{
      "type" => "reschedule",
      "enabled" => true,
      "attempts" => 0,
      "interval_ms" => @service_restart_interval_ms,
      "delay_ms" => @reschedule_service_delay_ms,
      "delay_function" => "exponential",
      "max_delay_ms" => @reschedule_service_max_delay_ms,
      "unlimited" => true
    }
  end

  defp reschedule_defaults(job_type, "cluster_recover") when job_type in ["batch", "sysbatch"] do
    %{
      "type" => "reschedule",
      "enabled" => true,
      "attempts" => 1,
      "interval_ms" => @batch_restart_interval_ms,
      "delay_ms" => @reschedule_batch_delay_ms,
      "delay_function" => "constant",
      "max_delay_ms" => @reschedule_batch_delay_ms,
      "unlimited" => false
    }
  end

  defp reschedule_defaults(job_type, _recovery_policy) do
    reschedule_defaults(job_type, "manual_recover")
  end

  defp normalize_restart_policy(policy, _job_type, _recovery_policy) do
    policy
    |> normalize_policy()
    |> Map.put("type", "restart")
    |> Map.put("mode", normalize_mode(policy["mode"], "fail"))
    |> Map.put("unlimited", false)
  end

  defp normalize_reschedule_policy(policy, _job_type, _recovery_policy) do
    policy
    |> normalize_policy()
    |> Map.put("type", "reschedule")
    |> Map.put("unlimited", policy["unlimited"] == true)
    |> Map.delete("mode")
  end

  defp normalize_policy(policy) when is_map(policy) do
    policy = stringify_keys(policy)

    %{
      "type" => Map.get(policy, "type", "lifecycle"),
      "enabled" => Map.get(policy, "enabled", true) != false,
      "attempts" => integer_value(Map.get(policy, "attempts"), 0),
      "interval_ms" => integer_value(Map.get(policy, "interval_ms"), @batch_restart_interval_ms),
      "delay_ms" => integer_value(Map.get(policy, "delay_ms"), 0),
      "delay_function" => normalize_delay_function(Map.get(policy, "delay_function")),
      "max_delay_ms" => integer_value(Map.get(policy, "max_delay_ms"), 0),
      "mode" => normalize_mode(Map.get(policy, "mode"), "fail"),
      "unlimited" => Map.get(policy, "unlimited") == true
    }
    |> clamp_max_delay()
  end

  defp normalize_policy(_policy), do: normalize_policy(%{})

  defp clamp_max_delay(%{"max_delay_ms" => max_delay, "delay_ms" => delay} = policy)
       when max_delay < delay do
    %{policy | "max_delay_ms" => delay}
  end

  defp clamp_max_delay(policy), do: policy

  defp merge_policy(policy, override) when is_map(override) do
    Map.merge(policy, stringify_keys(override))
  end

  defp merge_policy(policy, _override), do: policy

  defp agent_policy(_manifest, nil, _kind), do: %{}

  defp agent_policy(%Manifest{} = manifest, agent_id, kind) do
    manifest.nodes
    |> Enum.find(&(&1.node_id == agent_id))
    |> case do
      %{policies: policies} when is_map(policies) -> policy_map(policies, kind)
      _ -> %{}
    end
  end

  defp policy_map(policies, kind) when is_map(policies) do
    MirrorNeuron.SafeAccess.map_get(policies, kind, %{})
  end

  defp policy_map(_policies, _kind), do: %{}

  defp validate_node_policies(errors, nodes) do
    Enum.reduce(nodes, errors, fn node, acc ->
      validate_policy_container(
        acc,
        Map.get(node, :policies, %{}),
        "nodes.#{node.node_id}.policies"
      )
    end)
  end

  defp validate_restart_policy(errors, policy, _path) when policy in [%{}, nil], do: errors

  defp validate_restart_policy(errors, policy, path) when is_map(policy) do
    errors
    |> validate_nonnegative_integer(policy, path, "attempts")
    |> validate_nonnegative_integer(policy, path, "interval_ms")
    |> validate_nonnegative_integer(policy, path, "delay_ms")
    |> validate_nonnegative_integer(policy, path, "max_delay_ms")
    |> validate_in(policy, path, "mode", @restart_modes)
    |> validate_in(policy, path, "delay_function", @delay_functions)
  end

  defp validate_restart_policy(errors, _policy, path), do: ["#{path} must be an object" | errors]

  defp validate_reschedule_policy(errors, policy, _path) when policy in [%{}, nil], do: errors

  defp validate_reschedule_policy(errors, policy, path) when is_map(policy) do
    errors
    |> validate_nonnegative_integer(policy, path, "attempts")
    |> validate_nonnegative_integer(policy, path, "interval_ms")
    |> validate_nonnegative_integer(policy, path, "delay_ms")
    |> validate_nonnegative_integer(policy, path, "max_delay_ms")
    |> validate_boolean(policy, path, "unlimited")
    |> validate_in(policy, path, "delay_function", @delay_functions)
  end

  defp validate_reschedule_policy(errors, _policy, path),
    do: ["#{path} must be an object" | errors]

  defp validate_nonnegative_integer(errors, policy, path, key) do
    case Map.get(policy, key) do
      nil -> errors
      value when is_integer(value) and value >= 0 -> errors
      _ -> ["#{path}.#{key} must be a non-negative integer" | errors]
    end
  end

  defp validate_boolean(errors, policy, path, key) do
    case Map.get(policy, key) do
      nil -> errors
      value when is_boolean(value) -> errors
      _ -> ["#{path}.#{key} must be a boolean" | errors]
    end
  end

  defp validate_in(errors, policy, path, key, supported) do
    case Map.get(policy, key) do
      nil -> errors
      value when is_binary(value) -> validate_supported(errors, value, path, key, supported)
      value -> ["#{path}.#{key} has unsupported value #{inspect(value)}" | errors]
    end
  end

  defp validate_supported(errors, value, path, key, supported) do
    if String.downcase(value) in supported do
      errors
    else
      ["#{path}.#{key} has unsupported value #{inspect(value)}" | errors]
    end
  end

  defp active_history(policy, history, now) do
    interval_ms = integer_value(policy["interval_ms"], @batch_restart_interval_ms)

    history
    |> List.wrap()
    |> Enum.filter(fn entry ->
      with at when is_binary(at) <- Map.get(entry, "at"),
           {:ok, datetime, _offset} <- DateTime.from_iso8601(at) do
        DateTime.diff(now, datetime, :millisecond) <= interval_ms
      else
        _ -> false
      end
    end)
  end

  defp window_reset_at(_policy, []), do: nil

  defp window_reset_at(policy, history) do
    interval_ms = integer_value(policy["interval_ms"], @batch_restart_interval_ms)

    history
    |> Enum.map(&Map.get(&1, "at"))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> List.first()
    |> case do
      nil ->
        nil

      timestamp ->
        with {:ok, datetime, _offset} <- DateTime.from_iso8601(timestamp) do
          DateTime.add(datetime, interval_ms, :millisecond)
        else
          _ -> nil
        end
    end
  end

  defp normalize_delay_function(value) when is_binary(value) do
    value = String.downcase(value)
    if value in @delay_functions, do: value, else: "constant"
  end

  defp normalize_delay_function(_value), do: "constant"

  defp normalize_mode(value, default) when is_binary(value) do
    value = String.downcase(value)
    if value in @restart_modes, do: value, else: default
  end

  defp normalize_mode(_value, default), do: default

  defp fibonacci(attempt) when attempt <= 1, do: 1
  defp fibonacci(2), do: 1

  defp fibonacci(attempt) do
    Enum.reduce(3..attempt, {1, 1}, fn _index, {a, b} -> {b, a + b} end)
    |> elem(1)
  end

  defp manifest_from_job(%{"manifest" => manifest}) when is_map(manifest),
    do: Manifest.load(manifest)

  defp manifest_from_job(_job), do: {:error, :missing_manifest}

  defp source_agent_id(_job, nil), do: nil

  defp source_agent_id(job, agent_id) do
    job
    |> get_in(["scheduler", "placements"])
    |> List.wrap()
    |> Enum.find(&(Map.get(&1, "agent_id") == agent_id))
    |> case do
      %{"source_agent_id" => source} when is_binary(source) -> source
      _ -> agent_id
    end
  end

  defp job_type(job), do: job["job_type"] || get_in(job, ["scheduler", "job_type"]) || "batch"
  defp recovery_policy(job), do: job["recovery_policy"] || "local_restart"

  defp integer_value(value, _default) when is_integer(value) and value >= 0, do: value
  defp integer_value(value, default) when is_integer(value) and value < 0, do: default
  defp integer_value(value, default) when is_binary(value), do: parse_integer(value) || default
  defp integer_value(_value, default), do: default

  defp parse_integer(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, value}
    end)
  end

  defp timestamp(%DateTime{} = datetime),
    do: DateTime.to_iso8601(DateTime.truncate(datetime, :millisecond))

  defp timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp timestamp(_timestamp), do: Runtime.timestamp()

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)
end
