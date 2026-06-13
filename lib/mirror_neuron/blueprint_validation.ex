defmodule MirrorNeuron.BlueprintValidation do
  @moduledoc false

  alias MirrorNeuron.Cluster.Hardware
  alias MirrorNeuron.HardwareRequirements
  alias MirrorNeuron.JobBundle

  def force?(manifest) do
    metadata = map_value(manifest.metadata)
    validation = map_value(map_get(metadata, "mn_validation"))

    truthy?(map_get(validation, "force")) or truthy?(map_get(metadata, "force_validation"))
  end

  def run_input_validation(%JobBundle{manifest: manifest} = bundle) do
    if force?(manifest) do
      :ok
    else
      manifest.input_validation
      |> input_rules()
      |> Enum.reduce_while(:ok, fn rule, :ok ->
        case run_rule(rule, bundle) do
          :ok ->
            {:cont, :ok}

          {:error, issue} ->
            {:halt,
             {:error, "input_validation_failed: #{Jason.encode!(validation_report([issue]))}"}}
        end
      end)
    end
  end

  def check_requirements(manifest, snapshot \\ hardware_info()) do
    requirements = map_value(manifest.requirements)

    if force?(manifest) and not HardwareRequirements.hard_gpu_requirement?(requirements) do
      :ok
    else
      case requirement_violations(requirements, snapshot) do
        [] -> :ok
        issues -> {:error, "requirements_not_met: " <> Jason.encode!(validation_report(issues))}
      end
    end
  end

  def requirement_violations(requirements, _snapshot) when map_size(requirements) == 0,
    do: []

  def requirement_violations(requirements, snapshot) do
    capacity = capacity(snapshot)

    []
    |> maybe_requirement_violation(
      "cpu",
      min_value(requirements, "cpu"),
      capacity.cpu_cores,
      "cores"
    )
    |> maybe_requirement_violation(
      "gpu",
      min_value(requirements, "gpu"),
      capacity.gpu_count,
      "GPU(s)"
    )
    |> maybe_requirement_violation(
      "memory",
      min_size_gb(requirements, "memory"),
      capacity.memory_gb,
      "GB"
    )
    |> maybe_requirement_violation(
      "disk",
      min_size_gb(requirements, "disk"),
      capacity.disk_gb,
      "GB"
    )
    |> maybe_gpu_requirement_violation(requirements, snapshot)
    |> Enum.reverse()
  end

  defp maybe_gpu_requirement_violation(errors, requirements, snapshot) do
    case HardwareRequirements.gpu_requirement_issue(requirements, snapshot) do
      nil ->
        errors

      issue ->
        [
          issue(
            issue.code,
            issue.message,
            help: issue.help,
            source: "requirements",
            path: "gpu",
            expected: issue.expected,
            actual: issue.actual
          )
          | errors
        ]
    end
  end

  defp run_rule(rule, %JobBundle{} = bundle) when is_map(rule) do
    case map_get(rule, "type") do
      "pattern" ->
        run_pattern_rule(rule, bundle)

      "command" ->
        run_command_rule(rule, bundle)

      other ->
        {:error,
         issue(
           "manifest.input_validation.unsupported_type",
           "#{rule_name(rule)} has unsupported type #{inspect(other)}",
           source: "manifest",
           path: "input_validation.rules.type",
           expected: "pattern or command",
           actual: other,
           rule: rule_ref(rule)
         )}
    end
  end

  defp run_rule(_rule, _bundle),
    do:
      {:error,
       issue("manifest.input_validation.rule_type", "input validation rule must be an object",
         source: "manifest",
         path: "input_validation.rules",
         expected: "object"
       )}

  defp run_pattern_rule(rule, bundle) do
    source = rule |> map_get("source") |> default("config") |> to_string() |> String.downcase()
    path = rule |> map_get("path") |> default(map_get(rule, "input"))
    pattern = map_get(rule, "pattern")

    with true <-
           (is_binary(path) and path != "") or
             {:error,
              issue(
                "manifest.input_validation.pattern_path_missing",
                "#{rule_name(rule)} requires path",
                source: "manifest",
                path: "input_validation.rules.path",
                expected: "string",
                actual: path,
                rule: rule_ref(rule)
              )},
         true <-
           (is_binary(pattern) and pattern != "") or
             {:error,
              issue(
                "manifest.input_validation.pattern_missing",
                "#{rule_name(rule)} requires pattern",
                source: "manifest",
                path: "input_validation.rules.pattern",
                expected: "non-empty regex string",
                actual: pattern,
                rule: rule_ref(rule)
              )},
         {:ok, regex} <- Regex.compile(pattern, regex_options(rule)) do
      target =
        if source == "manifest",
          do: manifest_map(bundle.manifest),
          else: config_map(bundle.manifest)

      value = path_get(target, path)

      cond do
        is_nil(value) and map_get(rule, "required") == false ->
          :ok

        is_nil(value) ->
          {:error,
           issue(
             "config.required",
             map_get(rule, "message") || "#{rule_name(rule)} requires #{path}",
             help:
               map_get(rule, "help") || map_get(rule, "fix") ||
                 "Set #{path} before validating or running this blueprint.",
             source: source,
             path: path,
             expected: "present value",
             rule: rule_ref(rule)
           )}

        Regex.match?(regex, to_string(value)) ->
          :ok

        true ->
          {:error,
           issue(
             "config.pattern_mismatch",
             map_get(rule, "message") || "#{rule_name(rule)}: #{path} does not match #{pattern}",
             help:
               map_get(rule, "help") || map_get(rule, "fix") ||
                 "Use a value for #{path} that matches #{inspect(pattern)}.",
             source: source,
             path: path,
             expected: pattern,
             actual: value,
             rule: rule_ref(rule)
           )}
      end
    else
      {:error, %Regex.CompileError{} = error} ->
        {:error,
         issue(
           "manifest.input_validation.pattern_invalid",
           "#{rule_name(rule)} has invalid pattern: #{Exception.message(error)}",
           source: "manifest",
           path: "input_validation.rules.pattern",
           expected: "valid regex",
           actual: pattern,
           rule: rule_ref(rule)
         )}

      {:error, reason} ->
        {:error, reason}

      false ->
        {:error,
         issue("input_validation.invalid_rule", "#{rule_name(rule)} is invalid",
           source: "manifest",
           path: "input_validation.rules",
           rule: rule_ref(rule)
         )}
    end
  end

  defp run_command_rule(rule, %JobBundle{root_path: nil}),
    do:
      {:error,
       issue("validator.bundle_root_missing", "#{rule_name(rule)} requires a bundle root",
         source: "validator",
         rule: rule_ref(rule)
       )}

  defp run_command_rule(rule, %JobBundle{root_path: root_path} = bundle) do
    with {:ok, command} <- normalize_command(map_get(rule, "command")) do
      [executable | args] = command
      timeout_ms = timeout_ms(map_get(rule, "timeout_seconds"))
      env = validation_env(rule, bundle.manifest)

      task =
        Task.async(fn ->
          executable = executable_path(executable, root_path)

          try do
            {:ok,
             System.cmd(executable, args,
               cd: root_path,
               env: env,
               stderr_to_stdout: true
             )}
          rescue
            error in ErlangError -> {:error, Exception.message(error)}
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, {output, 0}}} ->
          case structured_command_report(output, rule) do
            {false, [issue | _]} -> {:error, issue}
            _ -> :ok
          end

        {:ok, {:ok, {output, status}}} ->
          case structured_command_report(output, rule) do
            {_ok, [issue | _]} ->
              {:error, issue}

            _ ->
              {:error,
               issue(
                 "validator.command_failed",
                 "#{rule_name(rule)} exited #{status}: #{String.trim(output)}",
                 help:
                   map_get(rule, "help") || map_get(rule, "fix") ||
                     "Review the input value and validator diagnostic output.",
                 source: "validator",
                 path: map_get(rule, "path") || map_get(rule, "input") || "",
                 expected: "validator exits with code 0",
                 actual: "exit code #{status}",
                 rule: rule_ref(rule),
                 debug: %{"output" => truncate_debug(output), "returncode" => status}
               )}
          end

        {:ok, {:error, reason}} ->
          {:error,
           issue("validator.command_unavailable", "#{rule_name(rule)} failed: #{reason}",
             help:
               map_get(rule, "help") || map_get(rule, "fix") ||
                 "Install the validation dependency or update the command path.",
             source: "validator",
             path: map_get(rule, "path") || map_get(rule, "input") || "",
             expected: "executable command",
             actual: List.first(command),
             rule: rule_ref(rule)
           )}

        nil ->
          {:error,
           issue(
             "validator.command_timeout",
             "#{rule_name(rule)} timed out after #{Float.round(timeout_ms / 1000, 1)}s",
             help:
               map_get(rule, "help") || map_get(rule, "fix") ||
                 "Check the input value or increase timeout_seconds for this validation rule.",
             source: "validator",
             path: map_get(rule, "path") || map_get(rule, "input") || "",
             expected: "command completes within #{Float.round(timeout_ms / 1000, 1)}s",
             actual: "timeout",
             rule: rule_ref(rule),
             debug: %{"timeout_seconds" => timeout_ms / 1000}
           )}
      end
    end
  rescue
    error in ErlangError ->
      {:error,
       issue("validator.command_failed", "#{rule_name(rule)} failed: #{Exception.message(error)}",
         source: "validator",
         path: map_get(rule, "path") || map_get(rule, "input") || "",
         rule: rule_ref(rule)
       )}
  end

  defp validation_report(issues) do
    normalized = Enum.map(issues, &normalize_issue/1)

    %{
      "version" => "validation.report/v1",
      "ok" => false,
      "status" => "failed",
      "error_count" => length(normalized),
      "errors" => Enum.map(normalized, &issue_message/1),
      "issues" => normalized,
      "results" => []
    }
  end

  defp issue(code, message, opts) do
    source = opts[:source]
    path = opts[:path]

    base = %{
      "code" => code,
      "message" => message,
      "help" => opts[:help] || "",
      "severity" => opts[:severity] || "error"
    }

    base
    |> maybe_put("location", location(source, path), source || path)
    |> maybe_put(
      "expected",
      redact_value(opts[:expected], path),
      Keyword.has_key?(opts, :expected)
    )
    |> maybe_put("actual", redact_value(opts[:actual], path), Keyword.has_key?(opts, :actual))
    |> maybe_put("rule", opts[:rule], opts[:rule])
    |> maybe_put("debug", redact_value(opts[:debug], "debug"), opts[:debug])
  end

  defp normalize_issue(%{} = raw) do
    location = map_value(map_get(raw, "location"))
    source = map_get(location, "source") || map_get(raw, "source") || "validator"
    path = map_get(location, "path") || map_get(raw, "path") || ""

    issue(
      map_get(raw, "code") || map_get(raw, "type") || "validation.failed",
      map_get(raw, "message") || map_get(raw, "detail") || map_get(raw, "msg") ||
        "Validation failed",
      help: map_get(raw, "help") || map_get(raw, "fix") || map_get(raw, "suggestion") || "",
      severity: map_get(raw, "severity") || "error",
      source: source,
      path: path,
      expected: map_get(raw, "expected"),
      actual: map_get(raw, "actual") || map_get(raw, "input"),
      rule: map_get(raw, "rule"),
      debug: map_get(raw, "debug")
    )
    |> put_in_pointer(map_get(location, "pointer"))
  end

  defp normalize_issue(other),
    do: issue("validation.failed", to_string(other), source: "validator")

  defp issue_message(issue) do
    location = map_value(map_get(issue, "location"))
    path = map_get(location, "path")

    message =
      to_string(map_get(issue, "message") || map_get(issue, "code") || "Validation failed")

    if is_binary(path) and path != "" and not String.contains?(message, path) do
      "#{path}: #{message}"
    else
      message
    end
  end

  defp location(source, path) do
    %{
      "source" => to_string(source || ""),
      "path" => to_string(path || ""),
      "pointer" => json_pointer(source, path)
    }
  end

  defp json_pointer(source, path) do
    parts =
      [source | String.split(to_string(path || ""), [".", "[", "]"], trim: true)]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(to_string(&1) == ""))
      |> Enum.map(&escape_pointer/1)

    "/" <> Enum.join(parts, "/")
  end

  defp escape_pointer(value) do
    value
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp put_in_pointer(issue, nil), do: issue
  defp put_in_pointer(issue, ""), do: issue

  defp put_in_pointer(issue, pointer) do
    update_in(issue, ["location"], fn location ->
      Map.put(map_value(location), "pointer", to_string(pointer))
    end)
  end

  defp maybe_put(map, _key, _value, nil), do: map
  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, _condition), do: Map.put(map, key, value)

  defp rule_ref(rule) do
    %{
      "name" => rule_name(rule),
      "type" => to_string(map_get(rule, "type") || "")
    }
  end

  defp structured_command_report(output, rule) do
    case decode_command_json(output) do
      {:ok, %{} = decoded} ->
        issues =
          cond do
            is_list(map_get(decoded, "issues")) ->
              map_get(decoded, "issues")

            is_list(map_get(decoded, "errors")) ->
              map_get(decoded, "errors")

            map_get(decoded, "code") || map_get(decoded, "message") || map_get(decoded, "detail") ->
              [decoded]

            true ->
              []
          end
          |> Enum.map(&normalize_command_issue(&1, rule))

        {map_get(decoded, "ok"), issues}

      _ ->
        {nil, []}
    end
  end

  defp normalize_command_issue(%{} = raw, rule) do
    raw
    |> Map.put_new("rule", rule_ref(rule))
    |> Map.put_new("source", "validator")
    |> Map.put_new("path", map_get(rule, "path") || map_get(rule, "input") || "")
    |> normalize_issue()
  end

  defp normalize_command_issue(raw, rule) do
    issue("validator.command_failed", to_string(raw),
      source: "validator",
      path: map_get(rule, "path") || map_get(rule, "input") || "",
      rule: rule_ref(rule)
    )
  end

  defp decode_command_json(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(:error, fn line ->
      if String.starts_with?(line, "{") do
        case Jason.decode(line) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> nil
        end
      end
    end)
  end

  defp decode_command_json(_output), do: :error

  defp normalize_command(command) when is_list(command) do
    if command != [] and Enum.all?(command, &(is_binary(&1) and &1 != "")) do
      {:ok, command}
    else
      {:error, "command validation requires a non-empty command list"}
    end
  end

  defp normalize_command(command) when is_binary(command) and command != "" do
    {:ok, shell_words(command)}
  end

  defp normalize_command(_command), do: {:error, "command validation requires a command"}

  defp shell_words(command), do: String.split(command)

  defp executable_path(executable, root_path) do
    if String.contains?(executable, "/") do
      Path.expand(executable, root_path)
    else
      executable
    end
  end

  defp validation_env(rule, manifest) do
    base_env = manifest_environment(manifest)

    rule
    |> map_get("env")
    |> map_value()
    |> Enum.reduce(base_env, fn {key, value}, acc ->
      Map.put(acc, to_string(key), resolve_env_template(to_string(value), base_env))
    end)
    |> Enum.map(fn {key, value} -> {key, value} end)
  end

  defp manifest_environment(manifest) do
    manifest.nodes
    |> List.wrap()
    |> Enum.find_value(%{}, fn node ->
      node
      |> Map.get(:config, %{})
      |> map_get("environment")
      |> case do
        env when is_map(env) -> stringify_map(env)
        _ -> nil
      end
    end)
  end

  defp resolve_env_template("$" <> name, env), do: Map.get(env, name, "")
  defp resolve_env_template(value, _env), do: value

  defp config_map(manifest) do
    manifest
    |> manifest_environment()
    |> Map.get("MN_BLUEPRINT_CONFIG_JSON")
    |> case do
      nil ->
        %{}

      json ->
        case Jason.decode(json) do
          {:ok, config} when is_map(config) -> config
          _ -> %{}
        end
    end
  end

  defp manifest_map(manifest), do: MirrorNeuron.Manifest.to_map(manifest)

  defp input_rules(validation) when is_list(validation), do: validation

  defp input_rules(validation) when is_map(validation) do
    case map_get(validation, "rules") do
      rules when is_list(rules) -> rules
      _ -> []
    end
  end

  defp input_rules(_validation), do: []

  defp capacity(snapshot) do
    snapshot = map_value(snapshot)

    {cpu, gpu, memory, disk} =
      case map_get(snapshot, "nodes") do
        nodes when is_list(nodes) ->
          {
            Enum.sum(Enum.map(nodes, &node_cpu_count/1)),
            Enum.sum(Enum.map(nodes, &node_gpu_count/1)),
            Enum.sum(Enum.map(nodes, &node_memory_gb/1)),
            Enum.sum(Enum.map(nodes, &node_disk_gb/1))
          }

        _nodes ->
          {
            number_or_zero(path_get(snapshot, "cpu.logical_processors")),
            gpu_count(map_get(snapshot, "gpu")),
            memory_gb(map_get(snapshot, "memory")),
            disk_available_gb(map_get(snapshot, "disk"))
          }
      end

    %{
      cpu_cores: floor_number(cpu),
      gpu_count: floor_number(gpu),
      memory_gb: Float.round(memory * 1.0, 2),
      disk_gb: Float.round(disk * 1.0, 2)
    }
  end

  defp maybe_requirement_violation(errors, _name, nil, _actual, _unit), do: errors

  defp maybe_requirement_violation(errors, name, minimum, actual, unit) when actual < minimum do
    [
      issue(
        "requirements.#{name}_insufficient",
        "#{name} requires at least #{minimum} #{unit}, found #{actual}",
        help:
          "Run this blueprint on a machine with at least #{minimum} #{unit} of #{name}, lower the blueprint requirement, or use --force intentionally.",
        source: "requirements",
        path: name,
        expected: %{"resource" => name, "minimum" => minimum, "unit" => unit},
        actual: %{"resource" => name, "available" => actual, "unit" => unit}
      )
      | errors
    ]
  end

  defp maybe_requirement_violation(errors, _name, _minimum, _actual, _unit), do: errors

  defp min_value(requirements, key) do
    requirements
    |> map_get(key)
    |> requirement_value(key)
  end

  defp min_size_gb(requirements, key) do
    value = map_get(requirements, key)

    cond do
      is_map(value) and not is_nil(map_get(value, "min_gb")) ->
        numeric(map_get(value, "min_gb"))

      is_map(value) and not is_nil(map_get(value, "gb")) ->
        numeric(map_get(value, "gb"))

      is_map(value) and not is_nil(map_get(value, "min_mb")) ->
        number_or_zero(map_get(value, "min_mb")) / 1024

      is_map(value) and not is_nil(map_get(value, "mb")) ->
        number_or_zero(map_get(value, "mb")) / 1024

      is_map(value) ->
        numeric(map_get(value, "min"))

      true ->
        parse_size_gb(value)
    end
  end

  defp requirement_value(nil, _key), do: nil

  defp requirement_value(value, key) when is_map(value) do
    keys =
      case key do
        "cpu" -> ["min_cores", "cores", "min"]
        "gpu" -> ["min_count", "count", "min"]
        _ -> ["min"]
      end

    Enum.find_value(keys, fn candidate -> map_get(value, candidate) end)
    |> numeric()
  end

  defp requirement_value(value, _key), do: numeric(value)

  defp parse_size_gb(value) when is_binary(value) do
    case Regex.run(~r/^\s*([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)\s*$/, value) do
      [_, number, unit] ->
        parsed = numeric(number)

        case String.downcase(unit) do
          unit when unit in ["mb", "mib"] -> parsed / 1024
          unit when unit in ["tb", "tib"] -> parsed * 1024
          _ -> parsed
        end

      _ ->
        nil
    end
  end

  defp parse_size_gb(value), do: numeric(value)

  defp memory_gb(memory) when is_map(memory) do
    cond do
      value = map_get(memory, "total_mb") -> number_or_zero(value) / 1024
      value = map_get(memory, "total_bytes") -> number_or_zero(value) / (1024 * 1024 * 1024)
      true -> 0
    end
  end

  defp memory_gb(_memory), do: 0

  defp disk_available_gb(disk) when is_map(disk) do
    cond do
      value = map_get(disk, "available_mb") -> number_or_zero(value) / 1024
      value = map_get(disk, "available_bytes") -> number_or_zero(value) / (1024 * 1024 * 1024)
      value = map_get(disk, "total_mb") -> number_or_zero(value) / 1024
      value = map_get(disk, "total_bytes") -> number_or_zero(value) / (1024 * 1024 * 1024)
      true -> 0
    end
  end

  defp disk_available_gb(_disk), do: 0

  defp node_cpu_count(node) when is_map(node) do
    node = map_value(node)

    number_or_zero(
      map_get(node, "cpu_cores") || path_get(node, "hardware.cpu.logical_processors")
    )
  end

  defp node_cpu_count(_node), do: 0

  defp node_gpu_count(node) when is_map(node) do
    node = map_value(node)

    cond do
      value = map_get(node, "gpu_count") -> number_or_zero(value)
      devices = map_get(node, "devices") -> gpu_count(devices)
      true -> gpu_count(path_get(node, "hardware.gpu"))
    end
  end

  defp node_gpu_count(_node), do: 0

  defp node_memory_gb(node) when is_map(node) do
    node = map_value(node)

    case map_get(node, "memory_total_gb") || map_get(node, "memory_gb") do
      nil -> memory_gb(path_get(node, "hardware.memory"))
      value -> number_or_zero(value)
    end
  end

  defp node_memory_gb(_node), do: 0

  defp node_disk_gb(node) when is_map(node) do
    node = map_value(node)

    case map_get(node, "disk_available_gb") || map_get(node, "disk_gb") do
      nil -> disk_available_gb(path_get(node, "hardware.disk"))
      value -> number_or_zero(value)
    end
  end

  defp node_disk_gb(_node), do: 0

  defp gpu_count(gpus) when is_list(gpus), do: length(gpus)

  defp gpu_count(gpu) when is_binary(gpu),
    do: if(String.contains?(String.downcase(gpu), "unknown"), do: 0, else: 1)

  defp gpu_count(_gpu), do: 0

  defp path_get(value, path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(value, fn part, acc ->
      cond do
        is_map(acc) ->
          map_get(acc, part)

        is_list(acc) and match?({_index, ""}, Integer.parse(part)) ->
          Enum.at(acc, String.to_integer(part))

        true ->
          nil
      end
    end)
  end

  defp path_get(_value, _path), do: nil

  defp redact_value(nil, _path), do: nil
  defp redact_value(value, _path) when is_number(value) or is_boolean(value), do: value

  defp redact_value(value, path) when is_binary(value) do
    if sensitive_name?(path || "") do
      "[redacted]"
    else
      value
      |> redact_url()
      |> truncate_debug()
    end
  end

  defp redact_value(value, path) when is_list(value) do
    value
    |> Enum.take(20)
    |> Enum.map(&redact_value(&1, path))
  end

  defp redact_value(value, path) when is_map(value) do
    value
    |> Enum.take(20)
    |> Enum.into(%{}, fn {key, nested} ->
      nested_path = [path, key] |> Enum.reject(&is_nil/1) |> Enum.join(".")
      {to_string(key), redact_value(nested, nested_path)}
    end)
  end

  defp redact_value(value, _path), do: inspect(value)

  defp redact_url(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        query =
          (uri.query || "")
          |> URI.decode_query()
          |> Enum.into(%{}, fn {key, query_value} ->
            if sensitive_name?(key), do: {key, "[redacted]"}, else: {key, query_value}
          end)
          |> URI.encode_query()

        %URI{uri | userinfo: nil, query: if(query == "", do: nil, else: query)}
        |> URI.to_string()

      _ ->
        value
    end
  rescue
    _ -> value
  end

  defp sensitive_name?(value) do
    value = String.downcase(to_string(value))

    Enum.any?(
      [
        "password",
        "passwd",
        "secret",
        "token",
        "api_key",
        "apikey",
        "authorization",
        "signature"
      ],
      &String.contains?(value, &1)
    )
  end

  defp truncate_debug(value, limit \\ 2000) do
    value = to_string(value || "")

    if String.length(value) > limit do
      String.slice(value, 0, limit - 20) <> "...[truncated]"
    else
      value
    end
  end

  defp map_get(map, key) when is_map(map),
    do:
      MirrorNeuron.SafeAccess.map_get(map, key) ||
        MirrorNeuron.SafeAccess.map_get(map, to_string(key))

  defp map_get(_map, _key), do: nil

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

  defp stringify_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp numeric(nil), do: nil
  defp numeric(value) when is_integer(value), do: value / 1
  defp numeric(value) when is_float(value), do: value

  defp numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp numeric(_value), do: nil

  defp number_or_zero(value), do: numeric(value) || 0
  defp floor_number(value), do: value |> number_or_zero() |> Kernel.*(1.0) |> Float.floor(2)

  defp default(nil, fallback), do: fallback
  defp default("", fallback), do: fallback
  defp default(value, _fallback), do: value

  defp regex_options(rule) do
    if map_get(rule, "ignore_case") == false, do: "", else: "i"
  end

  defp timeout_ms(nil), do: 30_000
  defp timeout_ms(value), do: max(trunc(number_or_zero(value) * 1000), 1)

  defp rule_name(rule),
    do: map_get(rule, "name") || map_get(rule, "id") || "input validation rule"

  defp truthy?(value) when value in [true, 1, "1", "true", "TRUE", "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp hardware_info do
    MirrorNeuron.Resource.list()
  rescue
    _error ->
      :mirror_neuron
      |> Application.get_env(:hardware_module, Hardware)
      |> apply(:info, [])
  end
end
