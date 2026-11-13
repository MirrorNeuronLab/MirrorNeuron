defmodule MirrorNeuron.Runtime.RunRetry.Configuration do
  @moduledoc "Declared bounded retry overrides and effective configuration presentation."

  def validate_overrides(manifest, overrides)
      when is_map(overrides) and map_size(overrides) <= 32 do
    fields = get_in(manifest.metadata, ["run_retry", "configuration_fields"]) || %{}

    if Enum.all?(overrides, fn {path, value} ->
         case fields[path] do
           %{"type" => "integer", "minimum" => low, "maximum" => high} ->
             is_integer(value) and value >= low and value <= high

           %{"type" => "string", "allowed_values" => values} ->
             is_binary(value) and value in values

           _ ->
             false
         end
       end),
       do: :ok,
       else:
         {:error,
          "Retry settings are not declared adjustable or are outside their allowed range."}
  end

  def validate_overrides(_, _), do: {:error, "Retry settings must be a bounded object."}

  def effective_overrides(job),
    do: get_in(job, ["retry_request", "effective_configuration_overrides"]) || %{}

  def effective_fields(job, manifest) do
    original =
      Enum.find_value(manifest.nodes, %{}, fn node ->
        case get_in(node.config, ["environment", "MN_BLUEPRINT_CONFIG_JSON"]) do
          value when is_binary(value) ->
            case Jason.decode(value) do
              {:ok, config} when is_map(config) -> config
              _ -> nil
            end

          _ ->
            nil
        end
      end)

    Map.new(get_in(manifest.metadata, ["run_retry", "configuration_fields"]) || %{}, fn {path,
                                                                                         field} ->
      value = Map.get(effective_overrides(job), path) || get_in(original, String.split(path, "."))
      {path, Map.put(field, "current_value", value)}
    end)
  end
end
