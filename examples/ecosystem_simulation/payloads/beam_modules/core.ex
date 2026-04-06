defmodule MirrorNeuron.Examples.EcosystemSimulation.Core do
  @traits [:metabolism, :forage, :breed, :aggression, :move, :longevity]

  def region_id(index), do: "region_" <> String.pad_leading(Integer.to_string(index), 2, "0")

  def trait_bounds do
    %{
      metabolism: {0.65, 1.45},
      forage: {0.55, 1.60},
      breed: {0.55, 1.55},
      aggression: {0.0, 1.20},
      move: {0.0, 1.20},
      longevity: {0.70, 1.65}
    }
  end

  def clamp(value, low, high), do: max(low, min(high, value))

  def round2(value), do: Float.round(value * 1.0, 2)

  def dna_key(dna) do
    "m#{format_trait(dna[:metabolism])}" <>
      "-f#{format_trait(dna[:forage])}" <>
      "-b#{format_trait(dna[:breed])}" <>
      "-a#{format_trait(dna[:aggression])}" <>
      "-v#{format_trait(dna[:move])}" <>
      "-l#{format_trait(dna[:longevity])}"
  end

  def build_region_profiles(seed, regions) do
    Enum.map(0..(regions - 1), fn index ->
      capacity_multiplier = rand_between(seed, index, 1, 0.78, 1.26)
      regen_multiplier = rand_between(seed, index, 2, 0.82, 1.18)
      harshness = rand_between(seed, index, 3, 0.05, 0.95)

      %{
        region_id: region_id(index),
        region_index: index,
        capacity_multiplier: round2(capacity_multiplier),
        regen_multiplier: round2(regen_multiplier),
        harshness: round2(harshness),
        lean_factor: round2(harshness * 0.8 + (1.0 - regen_multiplier) * 0.4),
        start_energy_bias: round2(rand_between(seed, index, 4, -4.0, 7.0)),
        forage_bonus: round2(rand_between(seed, index, 5, -0.06, 0.12)),
        shelter_bonus: round2(rand_between(seed, index, 6, 0.0, 0.08)),
        dna_bias: %{
          metabolism: round2(rand_between(seed, index, 7, -0.05, 0.05)),
          forage: round2(rand_between(seed, index, 8, -0.10, 0.10)),
          breed: round2(rand_between(seed, index, 9, -0.07, 0.07)),
          aggression: round2(rand_between(seed, index, 10, -0.10, 0.10)),
          move: round2(rand_between(seed, index, 11, -0.10, 0.10)),
          longevity: round2(rand_between(seed, index, 12, -0.08, 0.08))
        },
        neighbors: [region_id(rem(index + regions - 1, regions)), region_id(rem(index + 1, regions))],
        band: classify_band(capacity_multiplier, harshness)
      }
    end)
  end

  def animal_allocation(total, profiles, seed) do
    weights =
      Enum.with_index(profiles)
      |> Enum.map(fn {profile, index} ->
        base =
          profile.capacity_multiplier * 0.55 +
            profile.regen_multiplier * 0.30 +
            (1.10 - profile.harshness) * 0.25

        max(0.05, base + rand_between(seed, index, 30, 0.85, 1.15))
      end)

    weight_total = Enum.sum(weights)
    raw = Enum.map(weights, &(&1 * total / weight_total))
    base = Enum.map(raw, &floor/1)
    remainder = total - Enum.sum(base)

    order =
      raw
      |> Enum.with_index()
      |> Enum.sort_by(fn {value, index} -> {-(value - Enum.at(base, index)), -Enum.at(weights, index)} end)
      |> Enum.map(&elem(&1, 1))

    Enum.reduce(0..(length(base) - 1), base, fn index, acc ->
      if index < remainder do
        List.update_at(acc, Enum.at(order, index), &(&1 + 1))
      else
        acc
      end
    end)
  end

  def build_bootstrap(profile, initial_animals, simulation_seed, config) do
    max_food = config.max_food
    regen = config.food_regen_per_tick

    ratio =
      clamp(
        0.46 + profile.regen_multiplier * 0.18 +
          rand_between(simulation_seed, profile.region_index, 40, -0.08, 0.08),
        0.35,
        0.86
      )

    food_capacity = round2(max_food * profile.capacity_multiplier)

    %{
      simulation_seed: simulation_seed,
      region_seed: simulation_seed + profile.region_index * 17_123,
      initial_animals: initial_animals,
      initial_food: round2(food_capacity * ratio),
      food_capacity: food_capacity,
      food_regen_per_tick: round2(regen * profile.regen_multiplier),
      resource_profile: profile
    }
  end

  def init_region_state(region_id, bootstrap) do
    animals =
      if bootstrap.initial_animals <= 0 do
        []
      else
        Enum.map(0..(bootstrap.initial_animals - 1), fn serial ->
          create_animal(region_id, serial, bootstrap.region_seed, bootstrap.resource_profile)
        end)
      end

    %{
      region_id: region_id,
      region_index: bootstrap.resource_profile.region_index,
      region_seed: bootstrap.region_seed,
      simulation_seed: bootstrap.simulation_seed,
      tick: 0,
      food: bootstrap.initial_food,
      food_capacity: bootstrap.food_capacity,
      food_regen_per_tick: bootstrap.food_regen_per_tick,
      resource_profile: bootstrap.resource_profile,
      animals: animals,
      migration_inbox: %{},
      births: 0,
      deaths: 0,
      migrants_in: 0,
      migrants_out: 0,
      next_serial: length(animals),
      history: [],
      population_series: [
        %{
          tick: 0,
          population: length(animals)
        }
      ]
    }
  end

  def process_tick(state, config, tick) do
    {state, arrivals} = ingest_migrants(state, tick)
    flux = rand_between(state.simulation_seed, state.region_index, tick + 50, 0.92, 1.08)
    regenerated = state.food_regen_per_tick * flux
    state = %{state | food: round2(min(state.food_capacity, state.food + regenerated))}
    state = forage_pass(state, config, tick)
    {state, dead} = survivors_and_dead(state, config, tick)
    {state, births} = breed_animals(state, config, tick)
    {state, migration_payloads, outgoing} = choose_migrants(state, config, tick)

    state =
      state
      |> Map.put(:deaths, state.deaths + dead)
      |> Map.put(:births, state.births + births)
      |> Map.put(:migrants_out, state.migrants_out + outgoing)
      |> Map.put(:tick, tick)
      |> Map.update!(:history, fn history ->
        append_history_tail(history, %{
          tick: tick,
          population: length(state.animals),
          food: round2(state.food),
          food_capacity: round2(state.food_capacity),
          food_ratio: round2(state.food / max(state.food_capacity, 1.0)),
          births: births,
          deaths: dead
        })
      end)
      |> Map.update!(:population_series, fn series ->
        series ++
          [
            %{
              tick: tick,
              population: length(state.animals)
            }
          ]
      end)

    {state, arrivals, births, dead, migration_payloads, outgoing}
  end

  def lineage_snapshot(animals) do
    animals
    |> Enum.reduce(%{}, fn animal, acc ->
      Map.update(
        acc,
        animal.dna_key,
        %{
          dna: animal.dna,
          dna_key: animal.dna_key,
          alive: 1,
          avg_energy_total: animal.energy,
          generation_max: animal.generation
        },
        fn entry ->
          %{
            entry
            | alive: entry.alive + 1,
              avg_energy_total: entry.avg_energy_total + animal.energy,
              generation_max: max(entry.generation_max, animal.generation)
          }
        end
      )
    end)
    |> Enum.map(fn {_key, entry} ->
      Map.put(entry, :avg_energy, round2(entry.avg_energy_total / max(entry.alive, 1)))
      |> Map.delete(:avg_energy_total)
    end)
  end

  def compact_region_state(state) do
    %{
      region_id: state.region_id,
      tick: state.tick,
      population: length(state.animals),
      food: round2(state.food),
      food_capacity: round2(state.food_capacity),
      births: state.births,
      deaths: state.deaths,
      migrants_in: state.migrants_in,
      migrants_out: state.migrants_out,
      resource_band: get_in(state, [:resource_profile, :band]) || "uninitialized",
      history_tail: Enum.take(state.history, -3),
      top_lineages_preview:
        state.animals
        |> lineage_snapshot()
        |> Enum.sort_by(fn lineage -> {-lineage.alive, -lineage.generation_max, -lineage.avg_energy} end)
        |> Enum.take(3)
    }
  end

  def summarize_regions(region_summaries) do
    lineages =
      Enum.reduce(region_summaries, %{}, fn region_summary, acc ->
        Enum.reduce(region_summary.top_lineages, acc, fn lineage, lineage_acc ->
          Map.update(
            lineage_acc,
            lineage.dna_key,
            %{
              dna_key: lineage.dna_key,
              dna: lineage.dna,
              alive: lineage.alive,
              generation_max: lineage.generation_max,
              avg_energy_weighted: lineage.avg_energy * lineage.alive,
              regions_present: MapSet.new([region_summary.region_id])
            },
            fn entry ->
              %{
                entry
                | alive: entry.alive + lineage.alive,
                  generation_max: max(entry.generation_max, lineage.generation_max),
                  avg_energy_weighted: entry.avg_energy_weighted + lineage.avg_energy * lineage.alive,
                  regions_present: MapSet.put(entry.regions_present, region_summary.region_id)
              }
            end
          )
        end)
      end)

    ranked =
      lineages
      |> Enum.map(fn {_key, entry} ->
        avg_energy = round2(entry.avg_energy_weighted / max(entry.alive, 1))

        %{
          dna_key: entry.dna_key,
          dna: entry.dna,
          alive: entry.alive,
          generation_max: entry.generation_max,
          avg_energy: avg_energy,
          regions_present: entry.regions_present |> MapSet.to_list() |> Enum.sort(),
          fitness_score: round2(entry.alive * 100 + entry.generation_max * 5 + avg_energy)
        }
      end)
      |> Enum.sort_by(fn item -> {-item.alive, -item.generation_max, -item.avg_energy} end)
      |> Enum.take(10)

    %{
      mode: "ecosystem_simulation",
      simulation_seed: region_summaries |> List.first() |> Map.get(:simulation_seed),
      regions: Enum.map(region_summaries, & &1.region_id) |> Enum.sort(),
      region_count: length(region_summaries),
      population_alive: Enum.sum(Enum.map(region_summaries, & &1.population)),
      births: Enum.sum(Enum.map(region_summaries, & &1.births)),
      deaths: Enum.sum(Enum.map(region_summaries, & &1.deaths)),
      migrants_in: Enum.sum(Enum.map(region_summaries, & &1.migrants_in)),
      migrants_out: Enum.sum(Enum.map(region_summaries, & &1.migrants_out)),
      resource_profiles:
        Enum.into(region_summaries, %{}, fn summary -> {summary.region_id, summary.resource_profile} end),
      region_history_tail:
        Enum.into(region_summaries, %{}, fn summary ->
          {summary.region_id, Enum.take(summary.history_tail, -3)}
        end),
      region_nodes:
        Enum.into(region_summaries, %{}, fn summary -> {summary.region_id, summary.assigned_node} end),
      population_timeline: aggregate_population_timeline(region_summaries),
      top_10_dna: ranked
    }
  end

  def steps(config), do: max(1, div(config.duration_seconds, config.tick_seconds))

  def config_from_node(node) do
    %{
      total_animals: int_config(node.config, "total_animals", 2000),
      region_count: int_config(node.config, "region_count", 16),
      duration_seconds: int_config(node.config, "duration_seconds", 300),
      tick_seconds: int_config(node.config, "tick_seconds", 5),
      max_food: float_config(node.config, "max_food", 420.0),
      food_regen_per_tick: float_config(node.config, "food_regen_per_tick", 72.0),
      max_region_population: int_config(node.config, "max_region_population", 220),
      migration_rate: float_config(node.config, "migration_rate", 0.035),
      mutation_rate: float_config(node.config, "mutation_rate", 0.05),
      tick_delay_ms: int_config(node.config, "tick_delay_ms", 0),
      seed: int_config(node.config, "seed", 42),
      local_top_k: int_config(node.config, "local_top_k", 20),
      region_index: int_config(node.config, "region_index", 0)
    }
  end

  defp classify_band(capacity_multiplier, harshness) do
    cond do
      capacity_multiplier >= 1.12 and harshness <= 0.35 -> "lush"
      harshness >= 0.72 -> "harsh"
      true -> "balanced"
    end
  end

  defp create_animal(region_id, serial, rng, profile, dna \\ nil, generation \\ 0) do
    dna = dna || initial_dna(rng + serial * 97, profile)

    %{
      id: "#{region_id}-animal-#{serial |> Integer.to_string() |> String.pad_leading(5, "0")}",
      generation: generation,
      energy: round2(rand_between(rng, serial, 101, 74.0, 108.0) + profile.start_energy_bias),
      age: 0,
      dna: dna,
      dna_key: dna_key(dna)
    }
  end

  defp initial_dna(seed, profile) do
    samples = %{
      metabolism: rand_between(seed, 1, 1, 0.78, 1.28),
      forage: rand_between(seed, 1, 2, 0.70, 1.42),
      breed: rand_between(seed, 1, 3, 0.64, 1.36),
      aggression: rand_between(seed, 1, 4, 0.00, 1.00),
      move: rand_between(seed, 1, 5, 0.00, 1.00),
      longevity: rand_between(seed, 1, 6, 0.82, 1.44)
    }

    Enum.into(@traits, %{}, fn trait ->
      {low, high} = trait_bounds()[trait]
      value = clamp(samples[trait] + Map.fetch!(profile.dna_bias, trait), low, high)
      {trait, round2(value)}
    end)
  end

  defp ingest_migrants(state, tick) do
    arrivals = Map.get(state.migration_inbox, tick, [])
    inbox = Map.delete(state.migration_inbox, tick)

    state =
      if arrivals == [] do
        %{state | migration_inbox: inbox}
      else
        %{state | animals: state.animals ++ arrivals, migrants_in: state.migrants_in + length(arrivals), migration_inbox: inbox}
      end

    {state, arrivals}
  end

  defp forage_pass(state, config, tick) do
    scarcity = length(state.animals) / max(config.max_region_population * 1.0, 1.0)

    ranked =
      Enum.sort_by(state.animals, fn animal ->
        score =
          animal.dna.forage * jitter(state.simulation_seed, animal.id, tick + 100, 0.85, 1.22) +
            animal.dna.aggression * scarcity * 0.40

        -score
      end)

    {animals, food} =
      Enum.reduce(ranked, {[], state.food}, fn animal, {acc, food} ->
        upkeep =
          config.tick_seconds *
            (1.05 + animal.dna.metabolism * 1.30 + state.resource_profile.harshness * 0.30)

        appetite = 5.5 + animal.dna.forage * 2.8
        consumed = min(food, appetite)
        gain = consumed * (1.70 + animal.dna.forage * 0.58 + state.resource_profile.forage_bonus)

        updated =
          animal
          |> Map.put(:energy, round2(animal.energy + gain - upkeep))
          |> Map.put(:age, animal.age + config.tick_seconds)

        {[updated | acc], food - consumed}
      end)

    %{state | animals: Enum.reverse(animals), food: round2(max(food, 0.0))}
  end

  defp survivors_and_dead(state, config, tick) do
    carrying_capacity = carrying_capacity(state, config)
    density = length(state.animals) / max(carrying_capacity, 1)
    scarcity = max(0.0, 1.0 - state.food / max(state.food_capacity, 1.0))

    {survivors, dead} =
      Enum.reduce(state.animals, {[], 0}, fn animal, {acc, dead} ->
        max_age = 120 + animal.dna.longevity * 220
        age_ratio = clamp(animal.age / max(max_age, 1), 0.0, 1.0)

        death_probability =
          0.0015 +
            0.02 * density +
            0.18 * :math.pow(max(density - 0.92, 0.0), 2) +
            0.12 * :math.pow(scarcity, 2) +
            0.04 * :math.pow(age_ratio, 2) +
            0.015 * max(animal.dna.metabolism - 1.0, 0.0) -
            0.02 * max(animal.dna.longevity - 1.0, 0.0)
            |> clamp(0.0, 0.92)

        if animal.energy <= 0 or animal.age >= max_age or
             jitter(state.simulation_seed, animal.id, tick + 4_000, 0.0, 1.0) < death_probability do
          {acc, dead + 1}
        else
          {[animal | acc], dead}
        end
      end)

    {%{state | animals: Enum.reverse(survivors)}, dead}
  end

  defp breed_animals(state, config, tick) do
    max_population = carrying_capacity(state, config)
    density = length(state.animals) / max(max_population, 1)
    scarcity = max(0.0, 1.0 - state.food / max(state.food_capacity, 1.0))
    breed_factor = max(0.0, 1.0 - :math.pow(density, 2))
    resource_factor = max(0.0, 1.0 - :math.pow(scarcity, 1.6))
    energy_threshold = 92.0 + density * 18.0 + scarcity * 20.0

    eligible =
      state.animals
      |> Enum.sort_by(& &1.energy, :desc)
      |> Enum.filter(fn animal ->
        animal.age >= 20 and animal.energy >= energy_threshold and
          jitter(state.simulation_seed, animal.id, tick + 1_000, 0.0, 1.0) <=
            animal.dna.breed * (0.16 + state.resource_profile.shelter_bonus) * breed_factor *
              resource_factor
      end)

    {newborns, next_serial} = breed_pairs(eligible, [], state.next_serial, state, max_population, tick)
    animals = state.animals ++ newborns

    {%{state | animals: animals, next_serial: next_serial}, length(newborns)}
  end

  defp breed_pairs([parent_a, parent_b | rest], newborns, next_serial, state, max_population, tick) do
    if length(state.animals) + length(newborns) >= max_population do
      {Enum.reverse(newborns), next_serial}
    else
      seed = state.region_seed + next_serial * 131 + tick * 977
      child_dna = mix_dna(parent_a.dna, parent_b.dna, seed, state.mutation_rate)

      child =
        create_animal(
          state.region_id,
          next_serial,
          seed,
          state.resource_profile,
          child_dna,
          max(parent_a.generation, parent_b.generation) + 1
        )
        |> Map.put(:energy, round2(rand_between(seed, next_serial, 777, 46.0, 55.0)))

      breed_pairs(rest, [child | newborns], next_serial + 1, state, max_population, tick)
    end
  end

  defp breed_pairs(_parents, newborns, next_serial, _state, _max_population, _tick),
    do: {Enum.reverse(newborns), next_serial}

  defp mix_dna(left, right, seed, mutation_rate) do
    Enum.into(@traits, %{}, fn trait ->
      {low, high} = trait_bounds()[trait]
      blended = (Map.fetch!(left, trait) + Map.fetch!(right, trait)) / 2.0
      value = maybe_mutate(blended, seed, mutation_rate, trait)
      {trait, round2(clamp(value, low, high))}
    end)
  end

  defp maybe_mutate(value, seed, mutation_rate, trait) do
    if rand_between(seed, trait_seed(trait), 1, 0.0, 1.0) <= mutation_rate do
      value + rand_between(seed, trait_seed(trait), 2, -0.08, 0.08)
    else
      value
    end
  end

  defp choose_migrants(state, config, tick) do
    if state.animals == [] do
      {state, %{}, 0}
    else
      max_population = trunc(config.max_region_population * state.resource_profile.capacity_multiplier)
      crowding = max(0.0, (length(state.animals) - max_population * 0.72) / max_population)
      hunger = max(0.0, state.resource_profile.lean_factor * 0.55 - state.food / max(state.food_capacity, 1.0))

      limit =
        min(
          5,
          trunc(length(state.animals) * config.migration_rate + (crowding + hunger) * 5)
        )

      if limit <= 0 do
        {state, %{}, 0}
      else
        ranked =
          Enum.sort_by(state.animals, fn animal ->
            score =
              animal.dna.move * 1.45 + animal.dna.aggression * 0.25 +
                jitter(state.simulation_seed, animal.id, tick + 2_000, 0.0, 0.20)

            -score
          end)

        {movers, survivors} = Enum.split(ranked, limit)

        payloads =
          movers
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {animal, index}, acc ->
            destination = Enum.at(state.resource_profile.neighbors, rem(index, length(state.resource_profile.neighbors)))
            Map.update(acc, destination, [animal], &[animal | &1])
          end)
          |> Enum.into(%{}, fn {destination, animals} -> {destination, Enum.reverse(animals)} end)

        {%{state | animals: survivors}, payloads, length(movers)}
      end
    end
  end

  defp carrying_capacity(state, config) do
    max(1, trunc(config.max_region_population * state.resource_profile.capacity_multiplier))
  end

  defp append_history_tail(history, entry, limit \\ 24) do
    history
    |> Kernel.++([entry])
    |> Enum.take(-limit)
  end

  defp aggregate_population_timeline(region_summaries) do
    region_summaries
    |> Enum.flat_map(fn summary ->
      Enum.map(summary.population_series, fn entry ->
        %{tick: entry.tick, population: entry.population}
      end)
    end)
    |> Enum.group_by(& &1.tick)
    |> Enum.map(fn {tick, entries} ->
      %{
        tick: tick,
        population: Enum.sum(Enum.map(entries, & &1.population))
      }
    end)
    |> Enum.sort_by(& &1.tick)
  end

  defp rand_between(seed, index, salt, low, high) do
    unit = :erlang.phash2({seed, index, salt}, 1_000_000) / 999_999
    low + (high - low) * unit
  end

  defp trait_seed(trait), do: :erlang.phash2(trait)

  defp int_config(config, key, default), do: config |> Map.get(key, default) |> trunc()
  defp float_config(config, key, default), do: config |> Map.get(key, default) |> Kernel.*(1.0)

  defp format_trait(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp jitter(seed, key, salt, low, high), do: rand_between(seed, :erlang.phash2(key), salt, low, high)
end
