defmodule MirrorNeuron.Manifest.Loading do
  @moduledoc "Loads and normalizes executable manifests before validating their contracts."

  alias MirrorNeuron.ServiceSpec
  alias MirrorNeuron.Manifest.Topology
  alias MirrorNeuron.Manifest.Validation
  alias MirrorNeuron.Manifest.Values

  @known_top_level_keys MapSet.new([
                          "apiVersion",
                          "kind",
                          "manifest_version",
                          "graph_id",
                          "job_name",
                          "type",
                          "contract",
                          "flow",
                          "runtime",
                          "required_context_engine",
                          "requirements",
                          "skill_dependencies",
                          "input_validation",
                          "services",
                          "required_services",
                          "deployment",
                          "schedule",
                          "triggers",
                          "parameterized",
                          "response_service",
                          "metadata",
                          "nodes",
                          "edges",
                          "policies",
                          "entrypoints",
                          "initial_inputs",
                          "reload"
                        ])

  def load(%MirrorNeuron.Manifest{} = manifest), do: {:ok, manifest}

  def load(path) when is_binary(path) do
    if File.exists?(path) do
      with {:ok, raw} <- File.read(path),
           {:ok, decoded} <- Jason.decode(raw) do
        normalize_and_validate(decoded)
      else
        {:error, error} when is_exception(error) -> {:error, Exception.message(error)}
        {:error, reason} -> {:error, "failed to load manifest: #{inspect(reason)}"}
      end
    else
      case Jason.decode(path) do
        {:ok, decoded} -> normalize_and_validate(decoded)
        {:error, error} -> {:error, Exception.message(error)}
      end
    end
  end

  def load(map) when is_map(map), do: normalize_and_validate(map)

  defp normalize_and_validate(raw) do
    with :ok <- MirrorNeuron.Manifest.Shape.validate(raw) do
      normalize_valid_shape(raw)
    end
  end

  defp normalize_valid_shape(raw) do
    raw_nodes = raw_nodes(raw)
    raw_edges = raw_edges(raw)

    manifest = %MirrorNeuron.Manifest{
      api_version: Map.get(raw, "apiVersion"),
      kind: Map.get(raw, "kind"),
      manifest_version: Map.get(raw, "manifest_version"),
      type: normalize_type(Map.get(raw, "type")),
      graph_id: Map.get(raw, "graph_id"),
      job_name: Map.get(raw, "job_name") || Map.get(raw, "graph_id"),
      contract: normalize_optional_map(Map.get(raw, "contract")),
      flow: normalize_optional_map(Map.get(raw, "flow")),
      runtime: normalize_optional_map(Map.get(raw, "runtime")),
      required_context_engine:
        normalize_required_context_engine(Map.get(raw, "required_context_engine", false)),
      requirements: Map.get(raw, "requirements", %{}),
      skill_dependencies: normalize_optional_list(Map.get(raw, "skill_dependencies", [])),
      input_validation: Map.get(raw, "input_validation", %{}),
      services: ServiceSpec.normalize_services(Map.get(raw, "services", [])),
      required_services:
        ServiceSpec.normalize_required_services(Map.get(raw, "required_services", [])),
      deployment: normalize_deployment(Map.get(raw, "deployment", %{})),
      schedule: normalize_schedule(Map.get(raw, "schedule", %{})),
      triggers: normalize_triggers(Map.get(raw, "triggers", [])),
      parameterized: normalize_parameterized(Map.get(raw, "parameterized", %{})),
      response_service: normalize_response_service(Map.get(raw, "response_service")),
      metadata: Map.get(raw, "metadata", %{}),
      nodes: Enum.map(raw_nodes, &Topology.normalize_node/1),
      edges: Enum.map(raw_edges, &Topology.normalize_edge/1),
      policies: normalize_policies(Map.get(raw, "policies", %{})),
      entrypoints: normalize_entrypoints(Map.get(raw, "entrypoints"), raw_nodes),
      initial_inputs: normalize_initial_inputs(Map.get(raw, "initial_inputs", %{})),
      reload: normalize_reload(Map.get(raw, "reload", %{})),
      extensions: extension_fields(raw)
    }

    retired_errors = retired_manifest_errors(raw)

    case {retired_errors, Validation.validate(manifest)} do
      {[], :ok} -> {:ok, manifest}
      {errors, :ok} -> {:error, Enum.reverse(errors)}
      {[], {:error, errors}} -> {:error, errors}
      {retired_errors, {:error, errors}} -> {:error, errors ++ Enum.reverse(retired_errors)}
    end
  end

  defp raw_nodes(raw) do
    flow_nodes = get_in(raw, ["flow", "nodes"])

    cond do
      is_list(flow_nodes) -> flow_nodes
      true -> []
    end
  end

  defp raw_edges(raw) do
    flow_edges = get_in(raw, ["flow", "edges"])

    cond do
      is_list(flow_edges) -> flow_edges
      true -> []
    end
  end

  defp retired_manifest_errors(raw) do
    []
    |> Values.maybe_collect_error(
      Map.has_key?(raw, "nodes"),
      "top-level nodes is no longer supported; use flow.nodes"
    )
    |> Values.maybe_collect_error(
      Map.has_key?(raw, "edges"),
      "top-level edges is no longer supported; use flow.edges"
    )
    |> Values.maybe_collect_error(
      Map.has_key?(raw, "daemon"),
      "daemon is no longer supported; use type service"
    )
    |> Values.maybe_collect_error(Map.has_key?(raw, "requirments"), "use requirements")
    |> Values.maybe_collect_error(Map.has_key?(raw, "inputValidation"), "use input_validation")
    |> Values.maybe_collect_error(Map.has_key?(raw, "requiredServices"), "use required_services")
    |> Values.maybe_collect_error(
      Map.has_key?(raw, "requiredContextEngine"),
      "use required_context_engine"
    )
  end

  defp normalize_entrypoints(nil, raw_nodes) do
    raw_nodes
    |> Enum.filter(&(Map.get(&1, "role") in ["root", "root_coordinator"]))
    |> Enum.map(&Map.get(&1, "node_id"))
  end

  defp normalize_entrypoints(entrypoints, _raw_nodes) when is_list(entrypoints), do: entrypoints

  defp normalize_entrypoints(entrypoint, _raw_nodes) when is_binary(entrypoint), do: [entrypoint]

  defp normalize_entrypoints(_, _), do: []

  defp normalize_initial_inputs(inputs) when is_map(inputs) do
    Enum.into(inputs, %{}, fn {node_id, payload} ->
      values = if is_list(payload), do: payload, else: [payload]
      {node_id, values}
    end)
  end

  defp normalize_initial_inputs(inputs) when is_list(inputs) do
    %{"__entrypoints__" => inputs}
  end

  defp normalize_initial_inputs(_), do: %{}

  defp normalize_reload(reload) when is_map(reload) do
    %{
      mode: Map.get(reload, "mode", "manual"),
      interval_seconds: Map.get(reload, "interval_seconds", 60)
    }
  end

  defp normalize_reload(_), do: %{mode: "manual", interval_seconds: 60}

  defp normalize_deployment(deployment) when is_map(deployment), do: Values.json_safe(deployment)

  defp normalize_deployment(_deployment), do: %{}

  defp normalize_schedule(schedule) when is_map(schedule), do: Values.json_safe(schedule)

  defp normalize_schedule(_schedule), do: %{}

  defp normalize_triggers(triggers) when is_list(triggers),
    do: Enum.map(triggers, &Values.json_safe/1) |> Enum.filter(&is_map/1)

  defp normalize_triggers(trigger) when is_map(trigger), do: [Values.json_safe(trigger)]

  defp normalize_triggers(_triggers), do: []

  defp normalize_parameterized(parameterized) when is_map(parameterized),
    do: Values.json_safe(parameterized)

  defp normalize_parameterized(_parameterized), do: %{}

  defp normalize_response_service(nil), do: nil

  defp normalize_response_service(response_service) when is_map(response_service),
    do: Values.json_safe(response_service)

  defp normalize_response_service(response_service), do: response_service

  defp normalize_optional_map(value) when is_map(value), do: Values.json_safe(value)

  defp normalize_optional_map(_value), do: nil

  defp normalize_policies(nil), do: %{}

  defp normalize_policies(value), do: value

  defp normalize_optional_list(value) when is_list(value),
    do: Enum.map(value, &Values.json_safe/1)

  defp normalize_optional_list(_value), do: []

  defp extension_fields(raw) when is_map(raw) do
    raw
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@known_top_level_keys, key) end)
    |> Enum.into(%{}, fn {key, value} -> {key, Values.json_safe(value)} end)
  end

  defp normalize_type(nil), do: "batch"

  defp normalize_type(value) when is_binary(value), do: String.downcase(value)

  defp normalize_type(value), do: value

  defp normalize_required_context_engine(value) when is_boolean(value), do: value

  defp normalize_required_context_engine(value), do: value
end
