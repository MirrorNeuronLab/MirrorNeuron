defmodule MirrorNeuron.Runtime.RecoverySafety do
  @moduledoc false

  def decision(job, manifest, agents, opts \\ []) do
    scoped_agents = scoped_agents(agents, Keyword.get(opts, :agent_ids))

    cond do
      corrupt_checkpoint?(scoped_agents) ->
        {:blocked, "one or more agent checkpoints are corrupt; manual inspection is required"}

      missing_required_snapshots?(job, manifest, agents, opts) ->
        {:manual, "running job is missing one or more durable agent snapshots"}

      job["status"] == "paused" and not Keyword.get(opts, :manual_resume, false) ->
        {:manual, "job was paused before the runtime stopped"}

      Map.get(job, "recovery_policy", "local_restart") == "manual_recover" and
          not Keyword.get(opts, :manual_resume, false) ->
        {:manual, "workflow is configured for manual recovery"}

      unsafe_active_step?(manifest, scoped_agents) ->
        {:manual, "an in-progress or queued step may have unsafe side effects"}

      true ->
        {:auto, "all active checkpoints are safe to resume"}
    end
  end

  defp scoped_agents(agents, nil), do: agents

  defp scoped_agents(agents, agent_ids) do
    agent_ids =
      agent_ids
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.filter(agents, fn agent ->
      (agent["agent_id"] || agent["node_id"]) in agent_ids
    end)
  end

  defp corrupt_checkpoint?(agents) do
    Enum.any?(agents, fn agent ->
      recovery_state = get_in(agent, ["metadata", "recovery_state"])
      processed_messages = Map.get(agent, "processed_messages", 0)

      cond do
        is_binary(recovery_state) -> decode_checkpoint(recovery_state) == :error
        processed_messages > 0 -> true
        true -> false
      end
    end)
  end

  defp decode_checkpoint(encoded) do
    with {:ok, binary} <- Base.decode64(encoded) do
      _ = :erlang.binary_to_term(binary)
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp missing_required_snapshots?(%{"status" => "running"}, manifest, agents, opts) do
    required_ids =
      case Keyword.get(opts, :agent_ids) do
        nil -> Enum.map(manifest.nodes, & &1.node_id)
        agent_ids -> agent_ids |> List.wrap() |> Enum.map(&to_string/1)
      end

    agent_ids = agents |> Enum.map(&(&1["agent_id"] || &1["node_id"])) |> MapSet.new()

    Enum.any?(required_ids, &(not MapSet.member?(agent_ids, &1)))
  end

  defp missing_required_snapshots?(_job, _manifest, _agents, _opts), do: false

  defp unsafe_active_step?(manifest, agents) do
    nodes_by_id = Map.new(manifest.nodes, &{&1.node_id, &1})

    Enum.any?(agents, fn agent ->
      active_snapshot?(agent) and
        agent
        |> agent_node(nodes_by_id)
        |> node_requires_review?()
    end)
  end

  defp active_snapshot?(agent) do
    not is_nil(Map.get(agent, "inflight_message")) or
      Map.get(agent, "mailbox_depth", 0) > 0 or
      Map.get(agent, "pending_messages", []) != []
  end

  defp agent_node(agent, nodes_by_id) do
    Map.get(nodes_by_id, agent["agent_id"] || agent["node_id"]) ||
      %{agent_type: agent["agent_type"], config: %{}}
  end

  defp node_requires_review?(nil), do: true

  defp node_requires_review?(node) do
    config = Map.get(node, :config, %{})

    cond do
      truthy?(Map.get(config, "manual_review_on_recovery")) ->
        true

      truthy?(Map.get(config, "requires_approval")) ->
        true

      truthy?(Map.get(config, "unsafe")) ->
        true

      explicitly_false?(Map.get(config, "safe_to_retry")) ->
        true

      explicitly_false?(Map.get(config, "idempotent")) ->
        true

      unsafe_side_effects?(Map.get(config, "side_effects") || Map.get(config, "side_effect")) ->
        true

      node.agent_type == "executor" and not retry_safe?(config) ->
        true

      true ->
        false
    end
  end

  defp retry_safe?(config) do
    truthy?(Map.get(config, "safe_to_retry")) or
      truthy?(Map.get(config, "idempotent")) or
      non_empty?(Map.get(config, "idempotency_key")) or
      non_empty?(Map.get(config, "recovery_idempotency_key"))
  end

  defp unsafe_side_effects?(value)
       when value in [true, "true", "unsafe", "external", "write", "writes"],
       do: true

  defp unsafe_side_effects?(_value), do: false

  defp truthy?(value), do: value in [true, "true", "1", "yes"]
  defp explicitly_false?(value), do: value in [false, "false", "0", "no"]
  defp non_empty?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty?(_value), do: false
end
