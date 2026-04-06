defmodule MirrorNeuron.Examples.EcosystemSimulation.WatchASCII do
  alias MirrorNeuron.CLI.UI
  alias Owl.Data

  def main(argv) do
    argv =
      case argv do
        ["--" | rest] -> rest
        other -> other
      end

    {opts, positional, _invalid} =
      OptionParser.parse(argv,
        strict: [
          interval: :integer,
          frames: :integer,
          once: :boolean,
          no_clear: :boolean,
          box1_ip: :string,
          redis_url: :string,
          help: :boolean
        ]
      )

    if opts[:help] || positional == [] do
      IO.puts("""
      usage:
        mix run examples/ecosystem_simulation/watch_ascii.exs -- <job_id> [options]

      examples:
        mix run examples/ecosystem_simulation/watch_ascii.exs -- <job_id>
        mix run examples/ecosystem_simulation/watch_ascii.exs -- <job_id> --interval 2
        mix run examples/ecosystem_simulation/watch_ascii.exs -- <job_id> --box1-ip 192.168.4.29

      options:
            --interval <seconds>   Refresh interval, defaults to 2
            --frames <n>           Stop after n refreshes
            --once                 Render once and exit
            --no-clear             Do not clear the terminal between refreshes
            --box1-ip <ip>         Convenience option for redis://<ip>:6379/0
            --redis-url <url>      Override Redis URL
            --help                 Show this help
      """)

      System.halt(0)
    end

    job_id = hd(positional)
    interval_ms = max((opts[:interval] || 2) * 1_000, 250)
    frames = opts[:frames]
    once? = opts[:once] || false
    clear? = not (opts[:no_clear] || false)

    redis_url =
      cond do
        opts[:redis_url] -> opts[:redis_url]
        opts[:box1_ip] -> "redis://#{opts[:box1_ip]}:6379/0"
        true -> System.get_env("MIRROR_NEURON_REDIS_URL")
      end

    if redis_url do
      System.put_env("MIRROR_NEURON_REDIS_URL", redis_url)
      Application.put_env(:mirror_neuron, :redis_url, redis_url)
    end

    {:ok, _} = Application.ensure_all_started(:mirror_neuron)
    {:ok, _} = Application.ensure_all_started(:owl)

    live_screen? = UI.interactive?() and clear? and not once? and Process.whereis(Owl.LiveScreen)

    if live_screen? do
      Owl.LiveScreen.add_block(:ecosystem_watch,
        state: nil,
        render: fn
          nil -> UI.box("Loading", ["Preparing ecosystem dashboard..."], border_tag: :cyan)
          state -> render_dashboard(state)
        end
      )
    end

    render_loop(job_id, interval_ms, frames, once?, clear?, 1, live_screen?)
  end

  defp render_loop(job_id, interval_ms, frames, once?, clear?, frame, live_screen?) do
    job =
      case MirrorNeuron.inspect_job(job_id) do
        {:ok, value} -> value
        {:error, _} -> %{"job_id" => job_id, "status" => "unknown"}
      end

    agents =
      case MirrorNeuron.inspect_agents(job_id) do
        {:ok, value} -> value
        {:error, _} -> []
      end

    events =
      case MirrorNeuron.events(job_id) do
        {:ok, value} -> value
        {:error, _} -> []
      end

    world =
      Enum.find(agents, fn agent ->
        (agent["agent_id"] || "") == "world"
      end) || %{}

    world_state = extract_agent_state(world)
    world_config = world_state["config"] || %{}

    live_region_rows =
      agents
      |> Enum.filter(fn agent -> String.starts_with?(agent["agent_id"] || "", "region_") end)
      |> Enum.sort_by(&(&1["agent_id"] || ""))
      |> Enum.map(&region_row/1)

    final_fallback? =
      live_region_rows == [] or
        Enum.all?(live_region_rows, fn row ->
          row.tick == 0 and row.population == 0 and row.band == "unknown"
        end)

    observed_rows = observed_region_rows(events)

    region_rows =
      if final_fallback? and (job["status"] || "") in ["completed", "failed", "cancelled"] do
        final_region_rows(job)
      else
        bootstrap_rows = bootstrap_region_rows(agents, events)

        live_region_rows
        |> Enum.map(fn row ->
          if row.tick == 0 and row.population == 0 and row.band == "unknown" do
            Enum.find(bootstrap_rows, row, &(&1.id == row.id))
          else
            row
          end
        end)
        |> merge_observed_rows(observed_rows)
      end

    max_tick = Enum.max([0 | Enum.map(region_rows, & &1.tick)])
    min_tick =
      case region_rows do
        [] -> 0
        rows -> Enum.min(Enum.map(rows, & &1.tick))
      end
    total_ticks = calc_total_ticks(world_config)
    simulated_time = calc_simulated_time(max_tick, world_config)
    simulated_time_min = calc_simulated_time(min_tick, world_config)
    total_simulated_time = calc_total_simulated_time(world_config)
    completed_regions =
      if is_integer(total_ticks) and total_ticks > 0 do
        Enum.count(region_rows, &(&1.tick >= total_ticks))
      else
        0
      end
    total_population = Enum.sum(Enum.map(region_rows, & &1.population))
    total_food = Enum.sum(Enum.map(region_rows, & &1.food))
    total_births = Enum.sum(Enum.map(region_rows, & &1.births))
    total_deaths = Enum.sum(Enum.map(region_rows, & &1.deaths))
    total_migrants_in = Enum.sum(Enum.map(region_rows, & &1.migrants_in))
    total_migrants_out = Enum.sum(Enum.map(region_rows, & &1.migrants_out))
    active_nodes = region_rows |> Enum.map(& &1.node) |> Enum.reject(&(&1 == "-")) |> Enum.uniq() |> Enum.sort()
    leaderboard =
      if final_fallback? and (job["status"] || "") in ["completed", "failed", "cancelled"] do
        get_in(job, ["result", "output", "top_10_dna"]) || []
      else
        aggregate_lineages(region_rows) |> Enum.take(10)
      end
    recent_events = recent_events(events)

    render_state = %{
      job_id: job_id,
      status: job["status"] || "unknown",
      min_tick: min_tick,
      max_tick: max_tick,
      total_ticks: total_ticks,
      simulated_time_min: simulated_time_min,
      simulated_time: simulated_time,
      total_simulated_time: total_simulated_time,
      completed_regions: completed_regions,
      region_rows: region_rows,
      active_nodes: active_nodes,
      total_population: total_population,
      total_food: total_food,
      total_births: total_births,
      total_deaths: total_deaths,
      total_migrants_in: total_migrants_in,
      total_migrants_out: total_migrants_out,
      seed: world_state["seed"],
      leaderboard: leaderboard,
      recent_events: recent_events
    }

    if live_screen? do
      Owl.LiveScreen.update(:ecosystem_watch, render_state)
      Owl.LiveScreen.await_render()
    else
      if clear?, do: IO.write(IO.ANSI.home() <> IO.ANSI.clear())
      UI.puts(render_dashboard(render_state))
    end

    terminal? = (job["status"] || "") in ["completed", "failed", "cancelled"]
    done? = once? or terminal? or (is_integer(frames) and frame >= frames)

    unless done? do
      Process.sleep(interval_ms)
      render_loop(job_id, interval_ms, frames, once?, clear?, frame + 1, live_screen?)
    else
      if live_screen?, do: Owl.LiveScreen.flush()
    end
  end

  defp render_dashboard(state) do
    [
      UI.box(
        "Ecosystem Simulation",
        [
          status_line("Job", state.job_id),
          "\n",
          status_line("Status", state.status),
          "\n",
          status_line("Tick", format_tick_progress(state)),
          "\n",
          status_line("Sim Time", format_sim_time_progress(state)),
          "\n",
          status_line("Regions", Integer.to_string(length(state.region_rows))),
          "\n",
          status_line("Done", format_done_regions(state)),
          "\n",
          status_line("Nodes", Enum.join(state.active_nodes, ",")),
          maybe_seed_line(state.seed)
        ],
        border_tag: :cyan
      ),
      "\n",
      UI.box(
        "World Summary (Not Accurate Due To ES)",
        [
          status_line("Population", Integer.to_string(state.total_population)),
          "\n",
          status_line("Food", fmt(state.total_food)),
          "\n",
          status_line("Births", Integer.to_string(state.total_births)),
          "\n",
          status_line("Deaths", Integer.to_string(state.total_deaths)),
          "\n",
          status_line("Migrants", "#{state.total_migrants_in}/#{state.total_migrants_out}")
        ],
        border_tag: :green,
        title_tag: :green
      ),
      "\n",
      UI.box("Regions", region_table(state.region_rows), border_tag: :yellow, title_tag: :yellow),
      "\n",
      UI.box("Top DNA", dna_table(state.leaderboard), border_tag: :magenta, title_tag: :magenta),
      "\n",
      UI.box("Recent Events", event_lines(state.recent_events), border_tag: :light_black, title_tag: :light_black)
    ]
  end

  defp region_table(region_rows) do
    rows =
      Enum.map(region_rows, fn row ->
        food_ratio = row.food / row.food_capacity

        [
          pad(row.id, 10),
          pad(row.node, 5),
          pad(row.tick, 5),
          pad(row.population, 5),
          bar(food_ratio, 18),
          pad(food_level(row), 12),
          pad(food_trend(row), 5),
          pad(row.births, 6),
          pad(row.deaths, 6),
          pad(row.migrants_in, 4),
          pad(row.migrants_out, 4),
          row.band
        ]
      end)

    table(
      ["ID", "BOX", "TICK", "POP", "FOOD", "LEVEL", "TREND", "BIRTH", "DEATH", "IN", "OUT", "BAND"],
      rows
    )
  end

  defp dna_table(leaderboard) do
    rows =
      leaderboard
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} ->
        dna_key = entry[:dna_key] || entry["dna_key"] || "unknown"
        alive = entry[:alive] || entry["alive"] || 0
        avg_energy = entry[:avg_energy] || entry["avg_energy"] || 0.0
        generation_max = entry[:generation_max] || entry["generation_max"] || 0
        regions_present = entry[:regions_present] || entry["regions_present"] || 0

        [
          pad(index, 4),
          pad(truncate_key(dna_key), 36),
          pad(alive, 6),
          pad(fmt(avg_energy), 6),
          pad(generation_max, 4),
          format_regions_present(regions_present)
        ]
      end)

    table(["RANK", "DNA KEY", "ALIVE", "AVG_E", "GEN", "REGIONS"], rows)
  end

  defp event_lines([]), do: "No recent events."

  defp event_lines(events) do
    events
    |> Enum.map(fn event ->
      [
        Data.tag(pad(event["type"] || "unknown", 24), :cyan),
        " ",
        pad(inspect(event["agent_id"] || "-", limit: 4), 16),
        " ",
        summarize_payload(event["payload"] || %{})
      ]
    end)
    |> Enum.intersperse("\n")
  end

  defp table(headers, rows) do
    widths =
      headers
      |> Enum.with_index()
      |> Enum.map(fn {header, index} ->
        max(
          String.length(header),
          rows
          |> Enum.map(&(Enum.at(&1, index) || ""))
          |> Enum.map(&String.length/1)
          |> Enum.max(fn -> 0 end)
        )
      end)

    header_line =
      headers
      |> Enum.with_index()
      |> Enum.map(fn {header, index} ->
        header
        |> String.pad_trailing(Enum.at(widths, index))
        |> Data.tag(:cyan)
      end)
      |> Enum.intersperse("  ")

    separator =
      widths
      |> Enum.map(&String.duplicate("-", &1))
      |> Enum.intersperse("  ")

    body_lines =
      rows
      |> Enum.map(fn row ->
        row
        |> Enum.with_index()
        |> Enum.map(fn {value, index} -> String.pad_trailing(value, Enum.at(widths, index)) end)
        |> Enum.intersperse("  ")
      end)
      |> Enum.intersperse("\n")

    [header_line, "\n", separator, "\n", body_lines]
  end

  defp status_line(label, value) do
    [Data.tag(String.pad_trailing(label <> ":", 12), :yellow), " ", to_string(value)]
  end

  defp maybe_seed_line(nil), do: []
  defp maybe_seed_line(seed), do: ["\n", status_line("Seed", seed)]

  defp format_tick_progress(state) do
    total = state.total_ticks || "?"

    cond do
      state.min_tick == state.max_tick ->
        "#{state.max_tick}/#{total}"

      true ->
        "#{state.min_tick}-#{state.max_tick}/#{total}"
    end
  end

  defp format_sim_time_progress(state) do
    total = format_sim_time(state.total_simulated_time)

    cond do
      state.simulated_time_min == state.simulated_time ->
        "#{format_sim_time(state.simulated_time)}/#{total}"

      true ->
        "#{format_sim_time(state.simulated_time_min)}-#{format_sim_time(state.simulated_time)}/#{total}"
    end
  end

  defp format_done_regions(state) do
    "#{state.completed_regions}/#{length(state.region_rows)}"
  end

  defp region_row(agent) do
    state = extract_agent_state(agent)

    %{
      id: agent["agent_id"] || "unknown",
      node: short_node(agent["assigned_node"]),
      tick: state["tick"] || 0,
      population: state["population"] || 0,
      food: as_float(state["food"]),
      food_capacity: max(as_float(state["food_capacity"]), 1.0),
      births: state["births"] || 0,
      deaths: state["deaths"] || 0,
      migrants_in: state["migrants_in"] || 0,
      migrants_out: state["migrants_out"] || 0,
      band: state["resource_band"] || "unknown",
      history_tail: state["history_tail"] || [],
      top_lineages: state["top_lineages_preview"] || []
    }
  end

  defp bootstrap_region_rows(agents, events) do
    initialized =
      events
      |> Enum.filter(fn event -> (event["type"] || "") == "region_initialized" end)
      |> Enum.reduce(%{}, fn event, acc ->
        payload = event["payload"] || %{}
        region_id = payload["region_id"] || event["agent_id"]

        if is_binary(region_id) do
          Map.put(acc, region_id, payload)
        else
          acc
        end
      end)

    agents
    |> Enum.filter(fn agent -> String.starts_with?(agent["agent_id"] || "", "region_") end)
    |> Enum.sort_by(&(&1["agent_id"] || ""))
    |> Enum.map(fn agent ->
      region_id = agent["agent_id"] || "unknown"
      payload = Map.get(initialized, region_id, %{})

      %{
        id: region_id,
        node: short_node(agent["assigned_node"]),
        tick: 0,
        population: payload["population"] || 0,
        food: as_float(payload["food"]),
        food_capacity: max(as_float(payload["food_capacity"]), 1.0),
        births: 0,
        deaths: 0,
        migrants_in: 0,
        migrants_out: 0,
        band: payload["resource_band"] || "bootstrapping",
        history_tail: [],
        top_lineages: []
      }
    end)
  end

  defp calc_total_ticks(config) when is_map(config) do
    duration = int_value(config["duration_seconds"])
    tick = max(int_value(config["tick_seconds"]), 1)
    if duration > 0, do: max(div(duration, tick), 1), else: nil
  end

  defp calc_total_ticks(_), do: nil

  defp calc_simulated_time(tick, config) when is_map(config) do
    tick * max(int_value(config["tick_seconds"]), 1)
  end

  defp calc_simulated_time(_tick, _config), do: 0

  defp calc_total_simulated_time(config) when is_map(config), do: int_value(config["duration_seconds"])
  defp calc_total_simulated_time(_config), do: 0

  defp aggregate_lineages(region_rows) do
    region_rows
    |> Enum.flat_map(fn row ->
      Enum.map(row.top_lineages, fn lineage ->
        %{
          dna_key: lineage["dna_key"] || lineage[:dna_key] || "unknown",
          alive: int_value(lineage["alive"] || lineage[:alive]),
          avg_energy: as_float(lineage["avg_energy"] || lineage[:avg_energy]),
          generation_max: int_value(lineage["generation_max"] || lineage[:generation_max]),
          region_id: row.id
        }
      end)
    end)
    |> Enum.reduce(%{}, fn lineage, acc ->
      Map.update(
        acc,
        lineage.dna_key,
        %{lineage | regions_present: 1, weighted_energy: lineage.avg_energy * lineage.alive},
        fn existing ->
          %{
            existing
            | alive: existing.alive + lineage.alive,
              generation_max: max(existing.generation_max, lineage.generation_max),
              regions_present: existing.regions_present + 1,
              weighted_energy: existing.weighted_energy + lineage.avg_energy * lineage.alive
          }
        end
      )
    end)
    |> Enum.map(fn {_dna_key, entry} ->
      avg_energy = if entry.alive > 0, do: entry.weighted_energy / entry.alive, else: 0.0
      %{entry | avg_energy: avg_energy}
    end)
    |> Enum.sort_by(fn entry -> {-entry.alive, -entry.generation_max, -entry.avg_energy} end)
  end

  defp recent_events(events) do
    events
    |> Enum.reject(fn event ->
      (event["type"] || "") in ["agent_message_received"]
    end)
    |> Enum.take(-6)
  end

  defp observed_region_rows(events) do
    events
    |> Enum.filter(fn event -> (event["type"] || "") == "region_tick_processed" end)
    |> Enum.reduce(%{}, fn event, acc ->
      payload = event["payload"] || %{}
      region_id = payload["region_id"]

      if is_binary(region_id) do
        row = %{
          id: region_id,
          node: short_node(payload["assigned_node"]),
          tick: payload["tick"] || 0,
          population: payload["population"] || 0,
          food: as_float(payload["food"]),
          food_capacity: max(as_float(payload["food_capacity"]), 1.0),
          births: payload["births"] || 0,
          deaths: payload["deaths"] || 0,
          migrants_in: payload["arrivals"] || 0,
          migrants_out: payload["migrants_out"] || 0,
          band: payload["resource_band"] || "unknown",
          history_tail: [],
          top_lineages: []
        }

        case Map.get(acc, region_id) do
          nil -> Map.put(acc, region_id, row)
          existing when existing.tick <= row.tick -> Map.put(acc, region_id, row)
          _existing -> acc
        end
      else
        acc
      end
    end)
  end

  defp merge_observed_rows(rows, observed_rows) do
    rows
    |> Enum.map(fn row ->
      case Map.get(observed_rows, row.id) do
        nil -> row
        observed when observed.tick > row.tick -> merge_row(row, observed)
        _observed -> row
      end
    end)
  end

  defp merge_row(row, observed) do
    %{
      row
      | node: if(observed.node == "-", do: row.node, else: observed.node),
        tick: observed.tick,
        population: observed.population,
        food: observed.food,
        food_capacity: observed.food_capacity,
        births: observed.births,
        deaths: observed.deaths,
        migrants_in: observed.migrants_in,
        migrants_out: observed.migrants_out,
        band: if(observed.band == "unknown", do: row.band, else: observed.band)
    }
  end

  defp final_region_rows(job) do
    output = get_in(job, ["result", "output"]) || %{}
    history = output["region_history_tail"] || %{}
    profiles = output["resource_profiles"] || %{}
    region_nodes = output["region_nodes"] || %{}

    history
    |> Enum.sort_by(fn {region_id, _entries} -> region_id end)
    |> Enum.map(fn {region_id, entries} ->
      last = List.last(entries) || %{}
      profile = Map.get(profiles, region_id, %{})

      %{
        id: region_id,
        node: short_node(Map.get(region_nodes, region_id)),
        tick: last["tick"] || 0,
        population: last["population"] || 0,
        food: as_float(last["food"]),
        food_capacity: max(as_float(last["food_capacity"]), 1.0),
        births: last["births"] || 0,
        deaths: last["deaths"] || 0,
        migrants_in: 0,
        migrants_out: 0,
        band: profile["band"] || "unknown",
        history_tail: entries,
        top_lineages: []
      }
    end)
  end

  defp summarize_payload(payload) when map_size(payload) == 0, do: "-"

  defp summarize_payload(payload) do
    payload
    |> Enum.take(3)
    |> Enum.map(fn {key, value} -> "#{key}=#{format_value(value)}" end)
    |> Enum.join(" ")
  end

  defp format_value(value) when is_float(value), do: fmt(value)
  defp format_value(value) when is_binary(value), do: truncate_key(value, 18)
  defp format_value(value) when is_list(value), do: "[#{length(value)}]"
  defp format_value(value), do: inspect(value)

  defp format_regions_present(value) when is_list(value), do: Enum.join(value, ",")
  defp format_regions_present(value), do: to_string(value)

  defp format_sim_time(total_seconds) when is_integer(total_seconds) and total_seconds >= 0 do
    "#{total_seconds}y"
  end

  defp format_sim_time(_), do: "?"

  defp short_node(nil), do: "-"

  defp short_node(node) do
    case node |> to_string() |> String.split("@") |> hd() do
      "nonode" -> "local"
      value -> value
    end
  end

  defp bar(ratio, width) do
    ratio = ratio |> max(0.0) |> min(1.0)
    filled = trunc(Float.round(ratio * width))
    "[" <> String.duplicate("#", filled) <> String.duplicate(".", width - filled) <> "]"
  end

  defp food_level(row) do
    "#{fmt(row.food)}/#{fmt(row.food_capacity)}"
  end

  defp food_trend(row) do
    case Enum.take(row.history_tail || [], -2) do
      [prev, curr] ->
        prev_food = as_float(prev["food"] || prev[:food])
        curr_food = as_float(curr["food"] || curr[:food])
        delta = curr_food - prev_food

        cond do
          delta > 0.5 -> "up"
          delta < -0.5 -> "down"
          true -> "flat"
        end

      _ ->
        "-"
    end
  end

  defp pad(value, width), do: String.pad_trailing(to_string(value), width)

  defp truncate_key(value, limit \\ 36) do
    value = to_string(value)
    if String.length(value) <= limit, do: value, else: String.slice(value, 0, limit - 3) <> "..."
  end

  defp int_value(nil), do: 0
  defp int_value(value) when is_integer(value), do: value
  defp int_value(value) when is_float(value), do: trunc(value)
  defp int_value(value) when is_binary(value), do: String.to_integer(value)
  defp int_value(_), do: 0

  defp extract_agent_state(agent) do
    get_in(agent, ["current_state", "agent_state"]) || agent["current_state"] || %{}
  end

  defp as_float(nil), do: 0.0
  defp as_float(value) when is_float(value), do: value
  defp as_float(value) when is_integer(value), do: value * 1.0
  defp as_float(value) when is_binary(value), do: String.to_float(value)
  defp as_float(_), do: 0.0

  defp fmt(value), do: :erlang.float_to_binary(as_float(value), decimals: 1)
end

MirrorNeuron.Examples.EcosystemSimulation.WatchASCII.main(System.argv())
