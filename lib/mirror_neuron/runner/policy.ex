defmodule MirrorNeuron.Runner.Policy do
  @moduledoc false

  @openshell_module "MirrorNeuron.Runner.OpenShell"
  @forward_keys [
    "forward",
    "forwards",
    "port_forward",
    "port_forwards",
    "publish_ports",
    "published_ports"
  ]

  def validate_manifest(manifest) do
    manifest.nodes
    |> Enum.flat_map(&validate_node/1)
  end

  defp validate_node(node) do
    config = Map.get(node, :config) || Map.get(node, "config") || %{}
    resources = Map.get(node, :resources) || Map.get(node, "resources") || %{}
    node_id = Map.get(node, :node_id) || Map.get(node, "node_id") || "unknown"

    if openshell_runner?(config) do
      []
      |> maybe_error(
        declared_ports?(resources),
        "OpenShell node #{node_id} must not declare inbound resources.ports; use BEAM/core messaging or a DockerWorker/HostLocal service agent"
      )
      |> maybe_error(
        declares_forwards?(config),
        "OpenShell node #{node_id} must not publish or forward host ports"
      )
    else
      []
    end
  end

  defp openshell_runner?(config) when is_map(config) do
    runner = Map.get(config, "runner_module") || Map.get(config, :runner_module)

    cond do
      is_atom(runner) ->
        runner == MirrorNeuron.Runner.OpenShell or
          String.ends_with?(Atom.to_string(runner), ".OpenShell")

      is_binary(runner) ->
        runner == @openshell_module or String.ends_with?(runner, ".OpenShell")

      true ->
        false
    end
  end

  defp openshell_runner?(_config), do: false

  defp declared_ports?(resources) when is_map(resources) do
    case Map.get(resources, "ports") || Map.get(resources, :ports) do
      ports when is_list(ports) -> ports != []
      _ -> false
    end
  end

  defp declared_ports?(_resources), do: false

  defp declares_forwards?(config) when is_map(config) do
    Enum.any?(@forward_keys, fn key ->
      value = MirrorNeuron.SafeAccess.map_get(config, key)
      value not in [nil, [], %{}, "", false]
    end)
  end

  defp declares_forwards?(_config), do: false

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors
end
