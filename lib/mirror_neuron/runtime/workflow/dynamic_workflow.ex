defmodule MirrorNeuron.Runtime.DynamicWorkflow do
  @moduledoc "Atomic dynamic workflow patch and controller checkpoint API."

  alias MirrorNeuron.Runtime.DynamicWorkflow.Graph
  alias MirrorNeuron.Runtime.DynamicWorkflow.History
  alias MirrorNeuron.Runtime.DynamicWorkflow.Operations
  alias MirrorNeuron.Runtime.DynamicWorkflow.Requests
  alias MirrorNeuron.Runtime.DynamicWorkflow.State

  defdelegate initialize(state, flow, templates), to: State
  defdelegate enabled?(state), to: State
  defdelegate graph_revision(state), to: State
  defdelegate dynamic_step?(step), to: State
  defdelegate managed_target?(state, step), to: State
  defdelegate dependency_checkpointed?(state, edge), to: State
  defdelegate retire_completed_service_patches(state, now), to: History
  defdelegate public_state(state), to: State

  def apply_patch(state, controller_step, payload, now)
      when is_map(state) and is_map(controller_step) and is_map(payload) do
    with :ok <- State.ensure_dynamic_enabled(state),
         {:ok, request} <- Requests.normalize_patch_request(payload),
         {:ok, duplicate} <- Requests.deduplicate(state, request),
         :continue <- duplicate,
         {:ok, region} <- Requests.fetch_region(state, request.region_id),
         :ok <- Requests.authorize_controller(region, controller_step),
         :ok <- Requests.validate_revision(state, request.base_revision),
         :ok <- Requests.validate_patch_limits(state, request),
         {:ok, candidate, delta} <- Operations.apply_operations(state, region, request),
         :ok <- Graph.validate_candidate(candidate, region) do
      revision = State.graph_revision(state) + 1
      digest = Requests.patch_digest(request.raw)

      candidate =
        candidate
        |> Map.put("graph_revision", revision)
        |> put_in(["applied_patches", request.patch_id], %{
          "digest" => digest,
          "revision" => revision,
          "region_id" => request.region_id
        })
        |> Map.update("patch_order", [request.patch_id], &(&1 ++ [request.patch_id]))
        |> History.record_patch_instances(request, region, delta, revision, now)
        |> Map.put("updated_at", now)

      event = %{
        type: :workflow_graph_patch_applied,
        step: controller_step["id"],
        step_id: controller_step["id"],
        agent_id: primary_agent_id(controller_step),
        patch_id: request.patch_id,
        region_id: request.region_id,
        graph_revision: revision,
        strategy: region["strategy"],
        topology_delta: public_delta(delta),
        timestamp: now
      }

      {:ok, candidate, event, region["strategy"]}
    else
      {:duplicate, record, request} ->
        event = %{
          type: :workflow_graph_patch_replayed,
          step: controller_step["id"],
          step_id: controller_step["id"],
          agent_id: primary_agent_id(controller_step),
          patch_id: request.patch_id,
          region_id: request.region_id,
          graph_revision: record["revision"],
          timestamp: now
        }

        strategy =
          state
          |> get_in(["dynamic_regions", request.region_id, "strategy"])

        {:duplicate, state, event, strategy}

      {:error, reason} ->
        event =
          rejection_event(controller_step, payload, reason, now)
          |> Map.put(:graph_revision, State.graph_revision(state))

        {:error, state, event}

      other ->
        event =
          rejection_event(controller_step, payload, inspect(other), now)
          |> Map.put(:graph_revision, State.graph_revision(state))

        {:error, state, event}
    end
  end

  def apply_patch(state, controller_step, payload, now) do
    {:error, state,
     rejection_event(controller_step || %{}, payload || %{}, "invalid patch payload", now)}
  end

  def checkpoint(state, controller_step, payload, now)
      when is_map(state) and is_map(controller_step) and is_map(payload) do
    with :ok <- State.ensure_dynamic_enabled(state),
         {:ok, region} <- Requests.checkpoint_region(state, controller_step, payload),
         :ok <- Requests.authorize_controller(region, controller_step) do
      event = %{
        type: :workflow_controller_checkpointed,
        step: controller_step["id"],
        step_id: controller_step["id"],
        agent_id: primary_agent_id(controller_step),
        region_id: region["id"],
        graph_revision: State.graph_revision(state),
        timestamp: now
      }

      {:ok, Map.put(state, "updated_at", now), event}
    else
      {:error, reason} ->
        event =
          rejection_event(controller_step, payload, reason, now)
          |> Map.put(:type, :workflow_controller_checkpoint_rejected)
          |> Map.put(:graph_revision, State.graph_revision(state))

        {:error, state, event}
    end
  end

  def checkpoint(state, controller_step, payload, now) do
    {:error, state,
     rejection_event(
       controller_step || %{},
       payload || %{},
       "invalid controller checkpoint",
       now
     )}
  end

  defp public_delta(delta) do
    %{
      "steps_added" =>
        Enum.map(delta.steps_added, fn step ->
          Map.take(step, ["id", "label", "run", "agent_ids", "template_id", "region_id"])
        end),
      "steps_removed" => delta.steps_removed,
      "edges_added" =>
        Enum.map(
          delta.edges_added,
          &Map.take(&1, ["id", "from", "to", "accepts", "dynamic_region_id"])
        ),
      "edges_removed" => delta.edges_removed
    }
  end

  defp rejection_event(step, payload, reason, now) do
    %{
      type: :workflow_graph_patch_rejected,
      step: step["id"],
      step_id: step["id"],
      agent_id: primary_agent_id(step),
      patch_id: Requests.string_value(payload, "patch_id"),
      region_id: Requests.string_value(payload, "region_id"),
      graph_revision: Map.get(payload, "base_revision"),
      reason: reason,
      timestamp: now
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp primary_agent_id(%{"agent_ids" => [agent_id | _]}), do: agent_id

  defp primary_agent_id(_step), do: nil
end
