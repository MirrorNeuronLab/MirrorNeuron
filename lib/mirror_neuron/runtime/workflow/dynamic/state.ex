defmodule MirrorNeuron.Runtime.DynamicWorkflow.State do
  @moduledoc "Initializes dynamic regions, bounds configuration and exposes workflow state."

  alias MirrorNeuron.Runtime.DynamicWorkflow.Requests

  @batch_patch_default 64
  @service_patch_default 10_000
  @active_step_default 128
  @operation_default 64
  @instance_input_default 32 * 1024
  @patch_hard_cap 100_000
  @active_step_hard_cap 1_000
  @operation_hard_cap 256
  @history_default 256
  @terminal_statuses ["completed", "partial", "skipped", "failed"]

  def initialize(state, flow, templates) when is_map(state) and is_map(flow) do
    dynamic = if is_map(Map.get(flow, "dynamic")), do: Map.get(flow, "dynamic"), else: %{}
    mode = to_string(Map.get(flow, "mode") || "static_dag")
    enabled? = mode == "dynamic_dag" and Map.get(dynamic, "enabled") == true

    if enabled? do
      regions =
        dynamic
        |> Map.get("regions", [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Map.new(fn region ->
          {to_string(Map.get(region, "id") || ""), normalize_region(region)}
        end)

      limits = normalize_limits(dynamic, regions)
      mutable_owners = mutable_edge_owners(regions)

      edges =
        Enum.map(Map.get(state, "edges", []), fn edge ->
          case Map.get(mutable_owners, Map.get(edge, "id")) do
            nil ->
              edge

            region_id ->
              Map.merge(edge, %{"dynamic_region_id" => region_id, "dynamic_mutable" => true})
          end
        end)

      state
      |> Map.put("mode", mode)
      |> Map.put("dynamic_enabled", true)
      |> Map.put("graph_revision", 0)
      |> Map.put("dynamic_limits", limits)
      |> Map.put("dynamic_templates", templates)
      |> Map.put("dynamic_regions", regions)
      |> Map.put("applied_patches", %{})
      |> Map.put("patch_order", [])
      |> Map.put("dynamic_patch_instances", %{})
      |> Map.put("dynamic_history", [])
      |> Map.put("edges", edges)
    else
      state
      |> Map.put("mode", mode)
      |> Map.put("dynamic_enabled", false)
      |> Map.put_new("graph_revision", 0)
    end
  end

  def initialize(state, _flow, _templates), do: state

  def enabled?(%{"dynamic_enabled" => true, "mode" => "dynamic_dag"}), do: true

  def enabled?(_state), do: false

  def graph_revision(state), do: Map.get(state, "graph_revision", 0)

  def dynamic_step?(step) when is_map(step), do: Map.get(step, "dynamic_instance") == true

  def dynamic_step?(_step), do: false

  def managed_target?(state, step) when is_map(step) do
    dynamic_step?(step) or
      Enum.any?(Map.get(state, "edges", []), fn edge ->
        Map.get(edge, "to") == Map.get(step, "id") and
          (Map.get(edge, "dynamic_mutable") == true or
             is_binary(Map.get(edge, "dynamic_region_id")))
      end)
  end

  def dependency_checkpointed?(state, edge) when is_map(edge) do
    revision = Map.get(edge, "checkpoint_revision")
    is_integer(revision) and revision > 0 and revision <= graph_revision(state)
  end

  def public_state(state) when is_map(state) do
    state
    |> Map.drop(["dynamic_templates", "applied_patches", "dynamic_patch_instances"])
    |> Map.update("steps", %{}, fn steps ->
      Map.new(steps, fn {id, step} -> {id, Map.drop(step, ["instance_input"])} end)
    end)
  end

  defp normalize_region(region) do
    %{
      "id" => Requests.string_value(region, "id"),
      "strategy" => Requests.string_value(region, "strategy"),
      "controller" => Requests.string_value(region, "controller"),
      "exit" => Requests.string_value(region, "exit"),
      "templates" => string_list(Map.get(region, "templates")),
      "mutable_edges" => string_list(Map.get(region, "mutable_edges"))
    }
  end

  defp normalize_limits(dynamic, regions) do
    configured = if is_map(dynamic["limits"]), do: dynamic["limits"], else: %{}
    service? = Enum.any?(Map.values(regions), &(&1["strategy"] == "checkpoint_fanout"))
    default_patches = if service?, do: @service_patch_default, else: @batch_patch_default

    %{
      "max_patches" =>
        bounded_positive(configured["max_patches"], default_patches, @patch_hard_cap),
      "max_active_steps" =>
        bounded_positive(
          configured["max_active_steps"],
          @active_step_default,
          @active_step_hard_cap
        ),
      "max_operations_per_patch" =>
        bounded_positive(
          configured["max_operations_per_patch"],
          @operation_default,
          @operation_hard_cap
        ),
      "max_instance_input_bytes" =>
        positive_or_default(configured["max_instance_input_bytes"], @instance_input_default),
      "max_history" => bounded_positive(configured["max_history"], @history_default, 10_000)
    }
  end

  defp mutable_edge_owners(regions) do
    Enum.reduce(regions, %{}, fn {region_id, region}, owners ->
      Enum.reduce(region["mutable_edges"], owners, &Map.put(&2, &1, region_id))
    end)
  end

  def ensure_dynamic_enabled(state),
    do: if(enabled?(state), do: :ok, else: {:error, "dynamic workflow patches are not enabled"})

  def active_dynamic_step?(step),
    do: dynamic_step?(step) and step["status"] not in @terminal_statuses

  defp string_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp bounded_positive(value, _default, cap) when is_integer(value) and value > 0,
    do: min(value, cap)

  defp bounded_positive(_value, default, _cap), do: default

  defp positive_or_default(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_or_default(_value, default), do: default
end
