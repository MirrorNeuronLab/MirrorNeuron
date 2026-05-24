defmodule MirrorNeuron.Runtime.ProfileDistribution do
  @moduledoc false

  @behaviour Horde.DistributionStrategy

  alias MirrorNeuron.Execution.Profile

  def choose_node(child_spec, members) do
    profile = Map.get(child_spec, :mirror_neuron_execution_profile)
    target_node = Map.get(child_spec, :mirror_neuron_target_node)

    members
    |> Enum.filter(&match?(%{status: :alive}, &1))
    |> Enum.filter(&target_node_match?(target_node, &1))
    |> Enum.filter(&Profile.member_eligible?(profile, &1))
    |> case do
      [] when is_binary(target_node) and target_node != "" ->
        {:error, {:target_node_unavailable, target_node}}

      [] when is_binary(profile) ->
        {:error, {:no_eligible_execution_profile_nodes, profile}}

      [] ->
        {:error, :no_alive_nodes}

      eligible ->
        Horde.UniformDistribution.choose_node(child_spec, eligible)
    end
  end

  def has_quorum?(members), do: Horde.UniformDistribution.has_quorum?(members)

  defp target_node_match?(nil, _member), do: true
  defp target_node_match?("", _member), do: true

  defp target_node_match?(target_node, %{name: {_supervisor, node}}) do
    to_string(node) == target_node
  end

  defp target_node_match?(target_node, %{name: node}) do
    to_string(node) == target_node
  end

  defp target_node_match?(_target_node, _member), do: false
end
