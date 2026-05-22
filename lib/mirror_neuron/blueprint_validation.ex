defmodule MirrorNeuron.BlueprintValidation do
  @moduledoc false

  alias MirrorNeuron.Cluster.Hardware
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
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, "input_validation_failed: #{reason}"}}
        end
      end)
    end
  end

  def check_requirements(manifest, snapshot \\ hardware_info()) do
    if force?(manifest) do
      :ok
    else
      requirements = map_value(manifest.requirements)

      case requirement_violations(requirements, snapshot) do
        [] -> :ok
        violations -> {:error, "requirements_not_met: " <> Enum.join(violations, "; ")}
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
    |> Enum.reverse()
  end

  defp run_rule(rule, %JobBundle{} = bundle) when is_map(rule) do
    case map_get(rule, "type") do
      "pattern" -> run_pattern_rule(rule, bundle)
      "command" -> run_command_rule(rule, bundle)
      other -> {:error, "#{rule_name(rule)} has unsupported type #{inspect(other)}"}
    end
  end

  defp run_rule(_rule, _bundle), do: {:error, "input validation rule must be an object"}

  defp run_pattern_rule(rule, bundle) do
    source = rule |> map_get("source") |> default("config") |> to_string() |> String.downcase()
    path = rule |> map_get("path") |> default(map_get(rule, "input"))
    pattern = map_get(rule, "pattern")

    with true <- (is_binary(path) and path != "") or {:error, "#{rule_name(rule)} requires path"},
         true <-
           (is_binary(pattern) and pattern != "") or
             {:error, "#{rule_name(rule)} requires pattern"},
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
          {:error, "#{rule_name(rule)} requires #{path}"}

        Regex.match?(regex, to_string(value)) ->
          :ok

        true ->
          {:error,
           map_get(rule, "message") || "#{rule_name(rule)}: #{path} does not match #{pattern}"}
      end
    else
      {:error, %Regex.CompileError{} = error} ->
        {:error, "#{rule_name(rule)} has invalid pattern: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, reason}

      false ->
        {:error, "#{rule_name(rule)} is invalid"}
    end
  end

  defp run_command_rule(rule, %JobBundle{root_path: nil}),
    do: {:error, "#{rule_name(rule)} requires a bundle root"}

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
        {:ok, {:ok, {_output, 0}}} ->
          :ok

        {:ok, {:ok, {output, status}}} ->
          {:error, "#{rule_name(rule)} exited #{status}: #{String.trim(output)}"}

        {:ok, {:error, reason}} ->
          {:error, "#{rule_name(rule)} failed: #{reason}"}

        nil ->
          {:error, "#{rule_name(rule)} timed out after #{Float.round(timeout_ms / 1000, 1)}s"}
      end
    end
  rescue
    error in ErlangError ->
      {:error, "#{rule_name(rule)} failed: #{Exception.message(error)}"}
  end

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
    cpu = number_or_zero(path_get(snapshot, "cpu.logical_processors"))
    gpu = gpu_count(map_get(snapshot, "gpu"))
    memory = memory_gb(map_get(snapshot, "memory"))
    disk = disk_available_gb(map_get(snapshot, "disk"))

    %{
      cpu_cores: floor_number(cpu),
      gpu_count: floor_number(gpu),
      memory_gb: Float.round(memory, 2),
      disk_gb: Float.round(disk, 2)
    }
  end

  defp maybe_requirement_violation(errors, _name, nil, _actual, _unit), do: errors

  defp maybe_requirement_violation(errors, name, minimum, actual, unit) when actual < minimum do
    ["#{name} requires at least #{minimum} #{unit}, found #{actual}" | errors]
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

  defp map_get(map, key) when is_map(map),
    do:
      Map.get(map, key) || Map.get(map, to_string(key)) ||
        Map.get(map, String.to_atom(to_string(key)))

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
    :mirror_neuron
    |> Application.get_env(:hardware_module, Hardware)
    |> apply(:info, [])
  end
end
