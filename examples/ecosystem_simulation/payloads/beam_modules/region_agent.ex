defmodule MirrorNeuron.Examples.EcosystemSimulation.RegionAgent do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Examples.EcosystemSimulation.Core
  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime

  @impl true
  def init(node) do
    config = Core.config_from_node(node)

    {:ok,
     %{
       config: config,
       region_id: node.node_id,
       bootstrapped?: false,
       tick: 0,
       scheduled_tick: nil,
       schedule_seq: 0,
       simulation_seed: nil,
       resource_profile: %{},
       food: 0.0,
       food_capacity: 0.0,
       food_regen_per_tick: 0.0,
       animals: [],
       migration_inbox: %{},
       births: 0,
       deaths: 0,
       migrants_in: 0,
       migrants_out: 0,
       next_serial: 0,
       history: [],
       mutation_rate: config.mutation_rate
     }}
  end

  @impl true
  def handle_message(message, state, context) do
    case type(message) do
      "region_bootstrap" ->
        bootstrap = atomize(payload(message) || %{})

        next_state =
          Core.init_region_state(state.region_id, bootstrap)
          |> Map.put(:config, state.config)
          |> Map.put(:mutation_rate, state.config.mutation_rate)
          |> Map.put(:bootstrapped?, true)

        {:ok, next_state,
         [
           {:event, :region_initialized,
            %{
              "region_id" => next_state.region_id,
              "population" => length(next_state.animals),
              "food" => Core.round2(next_state.food),
              "food_capacity" => Core.round2(next_state.food_capacity),
              "resource_band" => next_state.resource_profile.band
            }}
         ]}
        |> then(fn {:ok, state, actions} ->
          {:ok, schedule_tick(state, context, 1), actions}
        end)

      "migration_batch" ->
        incoming = payload(message) || %{}
        arrival_tick = Map.get(incoming, "arrival_tick", state.tick + 2) |> trunc()
        migrants = atomize_animals(Map.get(incoming, "animals", []))

        inbox =
          Map.update(
            state.migration_inbox,
            arrival_tick,
            migrants,
            &(&1 ++ migrants)
          )

        next_state = %{state | migration_inbox: inbox}

        {:ok, next_state,
         [
           {:event, :migration_staged,
            %{
              "region_id" => state.region_id,
              "arrival_tick" => arrival_tick,
              "count" => length(migrants)
            }}
         ]}

      "region_tick" ->
        if state.bootstrapped? do
          run_tick(message, state, context)
        else
          {:ok, state,
           [
             {:event, :region_tick_skipped,
              %{"region_id" => state.region_id, "reason" => "region_not_bootstrapped"}}
           ]}
        end

      _ ->
        {:ok, state,
         [
           {:event, :region_message_ignored,
            %{"region_id" => state.region_id, "message_type" => type(message) || "unknown"}}
         ]}
    end
  end

  @impl true
  def inspect_state(state), do: Core.compact_region_state(state)

  @impl true
  def recover(state, context) do
    if state.bootstrapped? and state.tick < Core.steps(state.config) do
      {:ok, schedule_tick(state, context, state.tick + 1), []}
    else
      {:ok, state, []}
    end
  end

  defp run_tick(message, %{scheduled_tick: %{tick: tick, token: token}} = state, context) do
    incoming = payload(message) || %{}

    if Map.get(incoming, "tick") == tick and Map.get(incoming, "token") == token do
      state = %{state | scheduled_tick: nil}

      {next_state, arrivals, births, deaths, migration_payloads, outgoing} =
        Core.process_tick(state, state.config, tick)

      events = [
        {:event, :region_tick_processed,
         %{
           "region_id" => next_state.region_id,
           "tick" => next_state.tick,
           "population" => length(next_state.animals),
           "food" => Core.round2(next_state.food),
           "food_capacity" => Core.round2(next_state.food_capacity),
           "resource_band" => next_state.resource_profile.band,
           "assigned_node" => Atom.to_string(node()),
           "births" => births,
           "deaths" => deaths,
           "arrivals" => length(arrivals),
           "migrants_out" => outgoing
         }}
      ]

      migration_actions =
        Enum.map(migration_payloads, fn {destination, migrants} ->
          {:emit_to, destination, "migration_batch",
           %{
             "from_region" => next_state.region_id,
             "arrival_tick" => tick + 2,
             "animals" => migrants
           },
           [class: "event", headers: %{"schema_ref" => "com.mirrorneuron.ecosystem.migration"}]}
        end)

      if tick < Core.steps(state.config) do
        {:ok, schedule_tick(next_state, context, tick + 1), events ++ migration_actions}
      else
        summary = %{
          agent_id: next_state.region_id,
          region_id: next_state.region_id,
          assigned_node: Atom.to_string(node()),
          simulation_seed: next_state.simulation_seed,
          ticks_completed: next_state.tick,
          population: length(next_state.animals),
          food_remaining: Core.round2(next_state.food),
          births: next_state.births,
          deaths: next_state.deaths,
          migrants_in: next_state.migrants_in,
          migrants_out: next_state.migrants_out,
          history_tail: Enum.take(next_state.history, -10),
          population_series: next_state.population_series,
          resource_profile: next_state.resource_profile,
          top_lineages:
            next_state.animals
            |> Core.lineage_snapshot()
            |> Enum.sort_by(fn lineage ->
              {-lineage.alive, -lineage.generation_max, -lineage.avg_energy}
            end)
            |> Enum.take(next_state.config.local_top_k)
        }

        {:ok, next_state,
         events ++
           migration_actions ++
           [
             {:emit, "region_summary", summary,
              [
                class: "event",
                headers: %{"schema_ref" => "com.mirrorneuron.ecosystem.region_summary"}
              ]}
           ]}
      end
    else
      {:ok, state, []}
    end
  end

  defp run_tick(_message, state, _context), do: {:ok, state, []}

  defp schedule_tick(state, context, tick) do
    token = state.schedule_seq + 1
    delay_ms = state.config.tick_delay_ms

    spawn(fn ->
      if delay_ms > 0 do
        Process.sleep(delay_ms)
      end

      Runtime.deliver(
        context.job_id,
        context.node.node_id,
        Message.new(
          context.job_id,
          context.node.node_id,
          context.node.node_id,
          "region_tick",
          %{"tick" => tick, "token" => token},
          class: "control",
          headers: %{"schema_ref" => "com.mirrorneuron.ecosystem.tick"}
        )
      )
    end)

    %{state | scheduled_tick: %{tick: tick, token: token}, schedule_seq: token}
  end

  defp atomize(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      atom_key =
        case key do
          value when is_atom(value) -> value
          value when is_binary(value) -> String.to_atom(value)
        end

      {atom_key, atomize(value)}
    end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atomize_animals(animals), do: Enum.map(animals, &atomize/1)
end
