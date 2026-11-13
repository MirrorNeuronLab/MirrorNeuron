defmodule MirrorNeuron.BlueprintValidation.InputRules do
  @moduledoc "Applies declarative input patterns; command validation remains outside Core."

  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.BlueprintValidation.Reports
  alias MirrorNeuron.BlueprintValidation.Values

  def force?(manifest) do
    metadata = Values.map_value(manifest.metadata)
    validation = Values.map_value(Values.map_get(metadata, "mn_validation"))

    Values.truthy?(Values.map_get(validation, "force")) or
      Values.truthy?(Values.map_get(metadata, "force_validation"))
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
             {:error,
              "input_validation_failed: #{Jason.encode!(Reports.validation_report([issue]))}"}}
        end
      end)
    end
  end

  defp run_rule(rule, %JobBundle{} = bundle) when is_map(rule) do
    case Values.map_get(rule, "type") do
      "pattern" ->
        run_pattern_rule(rule, bundle)

      "command" ->
        run_command_rule(rule, bundle)

      other ->
        {:error,
         Reports.issue(
           "manifest.input_validation.unsupported_type",
           "#{Values.rule_name(rule)} has unsupported type #{inspect(other)}",
           source: "manifest",
           path: "input_validation.rules.type",
           expected: "pattern or command",
           actual: other,
           rule: Reports.rule_ref(rule)
         )}
    end
  end

  defp run_rule(_rule, _bundle),
    do:
      {:error,
       Reports.issue(
         "manifest.input_validation.rule_type",
         "input validation rule must be an object",
         source: "manifest",
         path: "input_validation.rules",
         expected: "object"
       )}

  defp run_pattern_rule(rule, bundle) do
    source =
      rule
      |> Values.map_get("source")
      |> Values.default("config")
      |> to_string()
      |> String.downcase()

    path = rule |> Values.map_get("path") |> Values.default(Values.map_get(rule, "input"))
    pattern = Values.map_get(rule, "pattern")

    with true <-
           (is_binary(path) and path != "") or
             {:error,
              Reports.issue(
                "manifest.input_validation.pattern_path_missing",
                "#{Values.rule_name(rule)} requires path",
                source: "manifest",
                path: "input_validation.rules.path",
                expected: "string",
                actual: path,
                rule: Reports.rule_ref(rule)
              )},
         true <-
           (is_binary(pattern) and pattern != "") or
             {:error,
              Reports.issue(
                "manifest.input_validation.pattern_missing",
                "#{Values.rule_name(rule)} requires pattern",
                source: "manifest",
                path: "input_validation.rules.pattern",
                expected: "non-empty regex string",
                actual: pattern,
                rule: Reports.rule_ref(rule)
              )},
         {:ok, regex} <- Regex.compile(pattern, Values.regex_options(rule)) do
      target =
        if source == "manifest",
          do: manifest_map(bundle.manifest),
          else: config_map(bundle.manifest)

      value = Values.path_get(target, path)

      cond do
        is_nil(value) and Values.map_get(rule, "required") == false ->
          :ok

        is_nil(value) ->
          {:error,
           Reports.issue(
             "config.required",
             Values.map_get(rule, "message") || "#{Values.rule_name(rule)} requires #{path}",
             help:
               Values.map_get(rule, "help") || Values.map_get(rule, "fix") ||
                 "Set #{path} before validating or running this blueprint.",
             source: source,
             path: path,
             expected: "present value",
             rule: Reports.rule_ref(rule)
           )}

        (is_binary(value) or is_number(value) or is_boolean(value)) and
            Regex.match?(regex, to_string(value)) ->
          :ok

        true ->
          {:error,
           Reports.issue(
             "config.pattern_mismatch",
             Values.map_get(rule, "message") ||
               "#{Values.rule_name(rule)}: #{path} does not match #{pattern}",
             help:
               Values.map_get(rule, "help") || Values.map_get(rule, "fix") ||
                 "Use a value for #{path} that matches #{inspect(pattern)}.",
             source: source,
             path: path,
             expected: pattern,
             actual: value,
             rule: Reports.rule_ref(rule)
           )}
      end
    else
      {:error, {message, position}} ->
        {:error,
         Reports.issue(
           "manifest.input_validation.pattern_invalid",
           "#{Values.rule_name(rule)} has invalid pattern at #{position}: #{message}",
           source: "manifest",
           path: "input_validation.rules.pattern",
           expected: "valid regex",
           actual: pattern,
           rule: Reports.rule_ref(rule)
         )}

      {:error, reason} ->
        {:error, reason}

      false ->
        {:error,
         Reports.issue("input_validation.invalid_rule", "#{Values.rule_name(rule)} is invalid",
           source: "manifest",
           path: "input_validation.rules",
           rule: Reports.rule_ref(rule)
         )}
    end
  end

  defp run_command_rule(rule, %JobBundle{root_path: nil}),
    do:
      {:error,
       Reports.issue(
         "validator.bundle_root_missing",
         "#{Values.rule_name(rule)} requires a bundle root",
         source: "validator",
         rule: Reports.rule_ref(rule)
       )}

  defp run_command_rule(rule, %JobBundle{}) do
    {:error,
     Reports.issue(
       "validator.command_prevalidation_required",
       "#{Values.rule_name(rule)} must be validated before Core submission",
       help:
         Values.map_get(rule, "help") || Values.map_get(rule, "fix") ||
           "Run command input validation in mn-python-sdk/API/CLI and submit only after it passes.",
       source: "validator",
       path: Values.map_get(rule, "path") || Values.map_get(rule, "input") || "",
       expected: "prevalidated command rule",
       actual: "command rule reached Core",
       rule: Reports.rule_ref(rule)
     )}
  end

  defp manifest_environment(manifest) do
    manifest.nodes
    |> List.wrap()
    |> Enum.find_value(%{}, fn node ->
      node
      |> Map.get(:config, %{})
      |> Values.map_get("environment")
      |> case do
        env when is_map(env) -> Values.stringify_map(env)
        _ -> nil
      end
    end)
  end

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
    case Values.map_get(validation, "rules") do
      rules when is_list(rules) -> rules
      _ -> []
    end
  end

  defp input_rules(_validation), do: []
end
