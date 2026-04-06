defmodule MirrorNeuron.Examples.EcosystemSimulation.WorldAgent do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Examples.EcosystemSimulation.Core

  @impl true
  def init(node) do
    {:ok,
     %{
       config: Core.config_from_node(node),
       bootstrapped?: false,
       seed: nil,
       profiles: []
     }}
  end

  @impl true
  def handle_message(message, state, _context) do
    payload = payload(message) || %{}

    if state.bootstrapped? do
      {:ok, state,
       [
         {:event, :world_bootstrap_reused,
          %{"seed" => state.seed, "regions" => state.config.region_count}}
       ]}
    else
      seed =
        case Map.get(payload, "seed") do
          nil -> state.config.seed
          value -> trunc(value)
        end

      profiles = Core.build_region_profiles(seed, state.config.region_count)
      allocations = Core.animal_allocation(state.config.total_animals, profiles, seed)

      emit_messages =
        profiles
        |> Enum.zip(allocations)
        |> Enum.map(fn {profile, initial_animals} ->
          {:emit_to, profile.region_id, "region_bootstrap",
           Core.build_bootstrap(profile, initial_animals, seed, state.config),
           [
             class: "command",
             headers: %{"schema_ref" => "com.mirrorneuron.ecosystem.bootstrap"}
           ]}
        end)

      {:ok,
       %{state | bootstrapped?: true, seed: seed, profiles: profiles},
       [
         {:event, :world_bootstrapped,
          %{
            "seed" => seed,
            "regions" => state.config.region_count,
            "total_animals" => state.config.total_animals
          }}
       ] ++ emit_messages}
    end
  end

  @impl true
  def inspect_state(state) do
    %{
      config: state.config,
      bootstrapped: state.bootstrapped?,
      seed: state.seed,
      profile_count: length(state.profiles)
    }
  end
end
