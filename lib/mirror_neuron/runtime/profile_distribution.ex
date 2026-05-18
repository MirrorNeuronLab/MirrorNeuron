defmodule MirrorNeuron.Runtime.ProfileDistribution do
  @moduledoc false

  @behaviour Horde.DistributionStrategy

  alias MirrorNeuron.Execution.Profile

  def choose_node(child_spec, members) do
    profile = Map.get(child_spec, :mirror_neuron_execution_profile)

    members
    |> Enum.filter(&match?(%{status: :alive}, &1))
    |> Enum.filter(&Profile.member_eligible?(profile, &1))
    |> case do
      [] when is_binary(profile) ->
        {:error, {:no_eligible_execution_profile_nodes, profile}}

      [] ->
        {:error, :no_alive_nodes}

      eligible ->
        Horde.UniformDistribution.choose_node(child_spec, eligible)
    end
  end

  def has_quorum?(members), do: Horde.UniformDistribution.has_quorum?(members)
end
