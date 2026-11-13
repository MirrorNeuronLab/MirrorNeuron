defmodule MirrorNeuron.Runtime.DynamicWorkflow.Requests do
  @moduledoc "Validates controller authority, patch identity, revisions and admission limits."

  alias MirrorNeuron.Runtime.DynamicWorkflow.State

  @id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/

  def normalize_patch_request(payload) do
    patch_id = string_value(payload, "patch_id")
    region_id = string_value(payload, "region_id")
    base_revision = Map.get(payload, "base_revision")
    operations = Map.get(payload, "operations")

    cond do
      not valid_id?(patch_id) ->
        {:error, "patch_id is required and must be a valid identifier"}

      not valid_id?(region_id) ->
        {:error, "region_id is required and must be a valid identifier"}

      not is_integer(base_revision) or base_revision < 0 ->
        {:error, "base_revision must be a non-negative integer"}

      not is_list(operations) or operations == [] ->
        {:error, "operations must be a non-empty list"}

      not Enum.all?(operations, &is_map/1) ->
        {:error, "every patch operation must be an object"}

      true ->
        raw = %{
          "patch_id" => patch_id,
          "region_id" => region_id,
          "base_revision" => base_revision,
          "operations" => operations
        }

        case Jason.encode(raw) do
          {:ok, _encoded} ->
            {:ok,
             %{
               patch_id: patch_id,
               region_id: region_id,
               base_revision: base_revision,
               operations: operations,
               raw: raw
             }}

          {:error, _reason} ->
            {:error, "patch operations must contain JSON-encodable values"}
        end
    end
  end

  def deduplicate(state, request) do
    case get_in(state, ["applied_patches", request.patch_id]) do
      nil ->
        {:ok, :continue}

      %{"digest" => digest} = record ->
        if digest == patch_digest(request.raw) do
          {:ok, {:duplicate, record, request}}
        else
          {:error, "patch_id #{request.patch_id} was already used with different content"}
        end
    end
  end

  def fetch_region(state, region_id) do
    case get_in(state, ["dynamic_regions", region_id]) do
      region when is_map(region) -> {:ok, region}
      _ -> {:error, "unknown dynamic region #{region_id}"}
    end
  end

  def checkpoint_region(state, controller_step, payload) do
    requested = string_value(payload, "region_id")

    regions =
      state
      |> Map.get("dynamic_regions", %{})
      |> Map.values()
      |> Enum.filter(
        &(Map.get(&1, "strategy") == "checkpoint_fanout" and
            Map.get(&1, "controller") == controller_step["id"])
      )

    region =
      if requested == "",
        do: List.first(regions),
        else: Enum.find(regions, &(Map.get(&1, "id") == requested))

    if region,
      do: {:ok, region},
      else: {:error, "controller does not own a checkpoint_fanout region"}
  end

  def authorize_controller(region, controller_step) do
    current_attempt = Map.get(controller_step, "current_attempt")

    if region["controller"] == controller_step["id"] and
         Map.get(controller_step, "status") in ["running", "queued"] and
         is_map(current_attempt) and
         Map.get(current_attempt, "agent_id") in Map.get(controller_step, "agent_ids", []) do
      :ok
    else
      {:error, "patch requester is not the region's active controller"}
    end
  end

  def validate_revision(state, revision) do
    if revision == State.graph_revision(state),
      do: :ok,
      else:
        {:error,
         "stale base_revision #{revision}; current revision is #{State.graph_revision(state)}"}
  end

  def validate_patch_limits(state, request) do
    limits = Map.get(state, "dynamic_limits", %{})
    patch_count = length(Map.get(state, "patch_order", []))

    dynamic_count =
      Enum.count(Map.values(Map.get(state, "steps", %{})), &State.active_dynamic_step?/1)

    cond do
      patch_count >= limits["max_patches"] ->
        {:error, "dynamic patch limit exceeded"}

      length(request.operations) > limits["max_operations_per_patch"] ->
        {:error, "patch operation limit exceeded"}

      dynamic_count > limits["max_active_steps"] ->
        {:error, "active dynamic step limit exceeded"}

      true ->
        :ok
    end
  end

  def patch_digest(value) do
    value
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value), do: value

  # Request normalization checks encodability before deduplication or mutation.
  def encoded_size(value), do: byte_size(Jason.encode!(value))

  def valid_id?(value), do: is_binary(value) and Regex.match?(@id_pattern, value)

  def string_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when value in [nil, false] -> ""
      value when is_binary(value) or is_number(value) or is_atom(value) -> to_string(value)
      _ -> ""
    end
  end

  def string_value(_map, _key), do: ""
end
