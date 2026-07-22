defmodule MirrorNeuron.Runtime.RecoverySafety do
  @moduledoc """
  Decides whether a lost job attempt may be redone automatically.

  Agent checkpoints are intentionally not considered. Recovery starts a new
  attempt from the persisted manifest and initial inputs, so retry eligibility
  must be a property of the manifest rather than of serialized process state.
  """

  def decision(job, manifest, _agent_observations \\ [], opts \\ []) do
    unsafe_nodes = unsafe_effectful_nodes(manifest)

    cond do
      Keyword.get(opts, :manual_resume, false) ->
        {:auto, "operator authorized a clean job attempt"}

      Keyword.get(opts, :force_paused, false) ->
        {:manual,
         Keyword.get(opts, :force_paused_reason, "job restart was requested in paused state")}

      job["status"] == "paused" ->
        {:manual, "job was paused before its owner stopped"}

      Map.get(job, "recovery_policy", "local_restart") == "manual_recover" ->
        {:manual, "workflow is configured for manual restart approval"}

      unsafe_nodes != [] ->
        {:manual,
         "clean restart requires approval because these effectful nodes do not declare retry safety: " <>
           Enum.join(unsafe_nodes, ", ")}

      true ->
        {:auto, "manifest permits a clean job attempt"}
    end
  end

  defp unsafe_effectful_nodes(manifest) do
    manifest.nodes
    |> Enum.filter(&effectful?/1)
    |> Enum.reject(&retry_safe?/1)
    |> Enum.map(& &1.node_id)
    |> Enum.sort()
  end

  defp effectful?(node) do
    node.agent_type in ["executor", "module"] or Map.get(node, :type) in ["executor", "module"]
  end

  defp retry_safe?(node) do
    config = Map.get(node, :config, %{})

    not explicit_review?(config) and
      (truthy?(config["safe_to_retry"]) or truthy?(config["idempotent"]) or
         non_empty?(config["idempotency_key"]) or
         non_empty?(config["recovery_idempotency_key"]))
  end

  defp explicit_review?(config) do
    truthy?(config["manual_review_on_recovery"]) or truthy?(config["requires_approval"]) or
      truthy?(config["unsafe"]) or config["safe_to_retry"] in [false, "false", "0", "no"] or
      config["idempotent"] in [false, "false", "0", "no"] or
      config["side_effects"] in [true, "true", "unsafe", "external", "write", "writes"] or
      config["side_effect"] in [true, "true", "unsafe", "external", "write", "writes"]
  end

  defp truthy?(value), do: value in [true, "true", "1", "yes"]
  defp non_empty?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty?(_value), do: false
end
