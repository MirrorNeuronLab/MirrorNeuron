defmodule MirrorNeuron.CLI.UI do
  alias MirrorNeuron.AgentRegistry
  alias Owl.Box
  alias Owl.Data
  alias Owl.IO, as: OwlIO

  @logo [
    " __  __ _                      _   _                      ",
    "|  \\/  (_)_ __ _ __ ___  _ __| \\ | | ___ _   _ _ __ ___ ",
    "| |\\/| | | '__| '__/ _ \\| '__|  \\| |/ _ \\ | | | '__/ _ \\",
    "| |  | | | |  | | | (_) | |  | |\\  |  __/ |_| | | | (_) |",
    "|_|  |_|_|_|  |_|  \\___/|_|  |_| \\_|\\___|\\__,_|_|  \\___/"
  ]

  @spinner_frames ["|", "/", "-", "\\"]

  def interactive? do
    match?(width when is_integer(width) and width > 0, OwlIO.columns())
  end

  def success(message) do
    [Data.tag("==>", :green), " ", Data.tag(message, :green)]
  end

  def error(message) do
    [Data.tag("==>", :red), " ", Data.tag(message, :red)]
  end

  def banner(command, subtitle \\ nil) do
    subtitle_data =
      case subtitle do
        nil -> nil
        "" -> nil
        value -> [Data.tag(command_label(command), :cyan), "  ", value]
      end

    body =
      @logo
      |> Enum.map(&Data.tag(&1, :cyan))
      |> Enum.intersperse("\n")
      |> then(fn logo ->
        [logo, "\n", Data.tag("Event-driven runtime for sandboxed agents", :light_black)]
        |> maybe_append_subtitle(subtitle_data)
      end)

    Box.new(body,
      title: Data.tag(" MirrorNeuron CLI ", :cyan),
      border_style: :solid_rounded,
      border_tag: :cyan,
      padding_x: 1,
      padding_y: 0,
      max_width: terminal_width()
    )
  end

  def section(title, details \\ nil) do
    suffix =
      case details do
        nil -> []
        "" -> []
        value -> ["  ", Data.tag(value, :light_black)]
      end

    [Data.tag("==>", :green), " ", Data.tag(title, :yellow), suffix]
  end

  def status_line(label, value, color \\ :cyan) do
    [Data.tag(pad_label(label), color), " ", value]
  end

  def box(title, body, opts \\ []) do
    Box.new(body,
      title: Data.tag(" #{title} ", Keyword.get(opts, :title_tag, :cyan)),
      border_style: Keyword.get(opts, :border_style, :solid_rounded),
      border_tag: Keyword.get(opts, :border_tag, :cyan),
      padding_x: Keyword.get(opts, :padding_x, 1),
      padding_y: Keyword.get(opts, :padding_y, 0),
      max_width: terminal_width()
    )
  end

  def manifest_summary(bundle) do
    manifest = bundle.manifest
    executor_count = Enum.count(manifest.nodes, &(canonical_type(&1.agent_type) == "executor"))

    aggregator_count =
      Enum.count(manifest.nodes, &(canonical_type(&1.agent_type) == "aggregator"))

    lines = [
      status_line("Graph", manifest.graph_id),
      "\n",
      status_line("Bundle", bundle.root_path),
      "\n",
      status_line("Nodes", Integer.to_string(length(manifest.nodes))),
      "\n",
      status_line("Entrypoints", Enum.join(manifest.entrypoints, ", ")),
      "\n",
      status_line("Executors", Integer.to_string(executor_count)),
      "\n",
      status_line("Aggregators", Integer.to_string(aggregator_count))
    ]

    box("Manifest Validated", lines, border_tag: :green, title_tag: :green)
  end

  def run_started(job_id, manifest) do
    lines = [
      status_line("Job", job_id),
      "\n",
      status_line("Graph", manifest.graph_id),
      "\n",
      status_line("Placement", Map.get(manifest.policies, "placement_policy", "local")),
      "\n",
      status_line("Recovery", Map.get(manifest.policies, "recovery_mode", "local_restart")),
      "\n\n",
      Data.tag("💡 Job launched successfully.", :yellow),
      "\n",
      Data.tag("   Press Ctrl+C to safely detach your terminal. The job will keep", :light_black),
      "\n",
      Data.tag("   running in the background (if submitted to a cluster/server).", :light_black),
      "\n",
      Data.tag("   To completely stop the execution, use: ", :light_black),
      Data.tag("mn cancel #{job_id}", :cyan)
    ]

    box("Job Submitted", lines, border_tag: :yellow, title_tag: :yellow)
  end

  def non_await_hint(job_id) do
    lines = [
      status_line("Job", job_id),
      "\n",
      "Use `mn job inspect ",
      job_id,
      "` or `mn job events ",
      job_id,
      "` to watch it."
    ]

    box("Run Detached", lines, border_tag: :yellow, title_tag: :yellow)
  end

  def job_summary(job_id, job) do
    lines =
      [
        status_line("Job", job_id),
        "\n",
        status_line(
          "Status",
          Map.get(job, "status", "unknown"),
          status_color(Map.get(job, "status"))
        ),
        "\n",
        status_line("Graph", Map.get(job, "graph_id", "-")),
        "\n",
        status_line("Updated", Map.get(job, "updated_at", "-"))
      ]
      |> maybe_append_result(job)

    box("Run Summary", lines, border_tag: status_color(Map.get(job, "status")))
  end

  def job_details(job) do
    lines =
      [
        {"Status", Map.get(job, "status", "-"), status_color(Map.get(job, "status"))},
        {"Graph", Map.get(job, "graph_id", "-"), :cyan},
        {"Job name", Map.get(job, "job_name", "-"), :cyan},
        {"Submitted", Map.get(job, "submitted_at", "-"), :cyan},
        {"Updated", Map.get(job, "updated_at", "-"), :cyan},
        {"Placement", Map.get(job, "placement_policy", "-"), :cyan},
        {"Recovery", Map.get(job, "recovery_policy", "-"), :cyan}
      ]
      |> Enum.map(fn {label, value, color} ->
        [status_line(label, stringify(value), color), "\n"]
      end)

    body =
      if result = Map.get(job, "result") do
        [
          lines,
          "\n",
          Data.tag("Result", :yellow),
          "\n",
          inspect(result, pretty: true, limit: :infinity)
        ]
      else
        lines
      end

    box("Job Details", body, border_tag: :cyan)
  end

  def nodes_table(nodes) do
    rows =
      Enum.map(nodes, fn node ->
        default_pool = fetch_default_pool(node)
        hw = fetch(node, :hardware, %{})
        cpu = fetch(hw, :cpu, %{}) |> fetch(:logical_processors, "-")
        mem = fetch(hw, :memory, %{}) |> fetch(:total_mb, "-")
        gpu = fetch(hw, :gpu, "-")

        [
          fetch(node, :name),
          if(fetch(node, :self?), do: "yes", else: "no"),
          stringify(length(fetch(node, :connected_nodes, []))),
          pool_summary(default_pool),
          "#{cpu} CPU, #{mem} MB, #{gpu}"
        ]
      end)

    box(
      "Cluster Nodes",
      table(["node", "self", "links", "default pool", "hardware"], rows),
      border_tag: :green,
      title_tag: :green
    )
  end

  def agents_table(agents) do
    rows =
      Enum.map(agents, fn agent ->
        [
          fetch(agent, :agent_id, fetch(agent, :node_id, "-")),
          fetch(agent, :agent_type, "-"),
          fetch(agent, :assigned_node, "-"),
          stringify(fetch(agent, :processed_messages, 0)),
          stringify(fetch(agent, :mailbox_depth, 0))
        ]
      end)

    box("Agents", table(["agent", "type", "assigned node", "processed", "mailbox"], rows))
  end

  def events_table(events) do
    rows =
      Enum.map(events, fn event ->
        [
          fetch(event, :timestamp, "-"),
          fetch(event, :type, "-"),
          fetch(event, :agent_id, "-"),
          summarize_payload(fetch(event, :payload))
        ]
      end)

    box("Events", table(["timestamp", "type", "agent", "payload"], rows), border_tag: :yellow)
  end

  def progress_panel(job_id, job, metrics, started_at, tick) do
    status = Map.get(job, "status", "starting")
    elapsed = format_elapsed(System.monotonic_time(:millisecond) - started_at)

    lines = [
      [
        status_badge(status),
        " ",
        Data.tag(job_id, :light_white),
        "  ",
        spinner(tick),
        "  ",
        status_line("Elapsed", elapsed, :yellow)
      ],
      "\n",
      result_line(metrics),
      "\n",
      bar_line("Sandboxes", metrics.sandbox_done, metrics.sandbox_total),
      "\n",
      lease_line(metrics),
      "\n",
      status_line("Events", stringify(metrics.total_events), :light_black),
      "\n",
      status_line("Last", format_event(metrics.last_event), :light_black)
    ]

    box("Runtime Progress", lines,
      border_tag: status_color(status),
      title_tag: status_color(status)
    )
  end

  def usage_screen do
    commands = [
      "mn standalone-start",
      "mn cluster start --node-id <id> --bind <ip:port> [--data-dir <dir>] [--join <seeds>]",
      "mn cluster join --node-id <id> --bind <ip:port> --seeds <seeds>",
      "mn cluster discover --seeds <seeds>",
      "mn cluster status",
      "mn cluster nodes",
      "mn cluster leave --node-id <id>",
      "mn cluster rebalance",
      "mn cluster elect-leader",
      "mn cluster health",
      "mn cluster reload --node-id <id>",
      "mn validate <job-folder>",
      "mn run <job-folder> [--json] [--timeout <ms>] [--no-await]",
      "mn monitor [--json] [--running-only] [--limit <n>]",
      "mn job list [--all]",
      "mn job inspect <job_id>",
      "mn job agents <job_id>",
      "mn job events <job_id>",
      "mn job pause <job_id>",
      "mn job resume <job_id>",
      "mn job cancel <job_id>",
      "mn job cleanup [--all]",
      "mn job send <job_id> <agent_id> <message.json>",
      "mn node list",
      "mn bundle reload <bundle_id>",
      "mn bundle check <bundle_id>"
    ]

    body = [
      commands
      |> Enum.map(&["  ", Data.tag("$", :green), " ", &1, "\n"]),
      "\n",
      box(
        "Flags",
        [
          "- `-v`, `--verbose`: show warnings in addition to errors\n",
          "- `--json`: emit machine-readable JSON where supported\n",
          "- `--no-await`: submit a job and return immediately\n",
          "- `--timeout <ms>`: override wait timeout for blocking run commands\n",
          "- `--all`: show terminal jobs in `job list`"
        ],
        border_tag: :yellow,
        title_tag: :yellow
      )
    ]

    box("Commands", body, border_tag: :cyan)
  end

  def server_ready(node_name) do
    lines = [
      status_line("Node", node_name, :green),
      "\n",
      status_line("Mode", "runtime server", :cyan),
      "\n",
      "Press Ctrl-C to stop."
    ]

    box("Server Ready", lines, border_tag: :green, title_tag: :green)
  end

  def error_box(reason) do
    box("Error", format_reason(reason), border_tag: :red, title_tag: :red)
  end

  def puts(data, device \\ :stdio) do
    OwlIO.puts(data, device)
  rescue
    _ -> IO.puts(device, IO.iodata_to_binary([data]))
  end

  def clear_progress do
    if interactive?() and Process.whereis(Owl.LiveScreen) do
      Owl.LiveScreen.flush()
    end
  end

  def start_progress_screen(initial_state) do
    if interactive?() and Process.whereis(Owl.LiveScreen) do
      Owl.LiveScreen.add_block(:mirror_neuron_progress,
        state: initial_state,
        render: fn state ->
          progress_panel(
            state.job_id,
            state.job,
            state.metrics,
            state.started_at,
            state.tick
          )
        end
      )
    end
  rescue
    _ -> :ok
  end

  def update_progress_screen(state) do
    if interactive?() and Process.whereis(Owl.LiveScreen) do
      Owl.LiveScreen.update(:mirror_neuron_progress, state)
    end
  rescue
    _ -> :ok
  end

  defp maybe_append_subtitle(data, nil), do: data
  defp maybe_append_subtitle(data, subtitle), do: [data, "\n", subtitle]

  defp maybe_append_result(lines, %{"result" => result}) do
    [
      lines,
      "\n",
      Data.tag("Result", :yellow),
      "\n",
      inspect(result, pretty: true, limit: :infinity)
    ]
  end

  defp maybe_append_result(lines, _job), do: lines

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
        |> String.upcase()
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

  defp bar_line(label, done, total) do
    width = max(div((terminal_width() || 88) - 34, 2), 12)
    total = normalize_total(total)
    done = min(done, total)
    filled = if total == 0, do: 0, else: round(done / total * width)
    empty = max(width - filled, 0)
    bar = "[" <> String.duplicate("#", filled) <> String.duplicate(".", empty) <> "]"

    [status_line(label, "#{done}/#{total}", :cyan), "  ", Data.tag(bar, :green)]
  end

  defp result_line(%{collected: collected, expected_results: expected_results})
       when is_integer(expected_results) and expected_results > 0 do
    bar_line("Results", collected, expected_results)
  end

  defp result_line(%{long_lived: true}) do
    [
      status_line("Results", "∞", :yellow),
      "  ",
      Data.tag("long-lived", :yellow)
    ]
  end

  defp result_line(%{collected: collected}) do
    [
      status_line("Results", "#{collected} seen", :cyan),
      "  ",
      Data.tag("open-ended", :yellow)
    ]
  end

  defp lease_line(metrics) do
    waiting = metrics.leases_waiting
    running = metrics.leases_running

    [
      status_line("Leases", "run=#{running} wait=#{waiting}", :cyan),
      "  ",
      if(waiting > 0, do: Data.tag("queue active", :yellow), else: Data.tag("balanced", :green))
    ]
  end

  defp spinner(tick),
    do: Data.tag(Enum.at(@spinner_frames, rem(tick, length(@spinner_frames))), :yellow)

  defp status_badge("completed"), do: Data.tag("[DONE]", :green)
  defp status_badge("failed"), do: Data.tag("[FAIL]", :red)
  defp status_badge("cancelled"), do: Data.tag("[STOP]", :yellow)
  defp status_badge("running"), do: Data.tag("[RUN ]", :cyan)
  defp status_badge("starting"), do: Data.tag("[BOOT]", :yellow)

  defp status_badge(other),
    do: Data.tag("[#{String.pad_trailing(stringify(other), 4)}]", :light_black)

  defp status_color("completed"), do: :green
  defp status_color("failed"), do: :red
  defp status_color("cancelled"), do: :yellow
  defp status_color("running"), do: :cyan
  defp status_color("starting"), do: :yellow
  defp status_color(_), do: :cyan

  defp command_label(:validate), do: "Validate"
  defp command_label(:run), do: "Run"
  defp command_label(:inspect), do: "Inspect"
  defp command_label(:server), do: "Server"
  defp command_label(command), do: command |> stringify() |> String.capitalize()

  defp fetch(map, key, default \\ nil) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, to_string(key)) -> Map.get(map, to_string(key))
      true -> default
    end
  end

  defp fetch_default_pool(node) do
    pools = fetch(node, :executor_pools, %{})
    Map.get(pools, "default") || Map.get(pools, :default) || %{}
  end

  defp pool_summary(pool) when map_size(pool) == 0, do: "-"

  defp pool_summary(pool) do
    available = fetch(pool, :available, 0)
    capacity = fetch(pool, :capacity, 0)
    queued = fetch(pool, :queued, 0)
    "#{available}/#{capacity} free q=#{queued}"
  end

  defp summarize_payload(nil), do: "-"

  defp summarize_payload(payload) do
    payload
    |> inspect(limit: 3, pretty: false)
    |> String.replace("\n", " ")
    |> String.slice(0, 48)
  end

  defp normalize_total(value) when is_integer(value) and value > 0, do: value
  defp normalize_total(_), do: 1

  defp pad_label(label), do: String.pad_trailing(label <> ":", 12)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_list(reason), do: Enum.join(reason, "; ")
  defp format_reason(reason), do: inspect(reason, pretty: true, limit: :infinity)

  defp stringify(nil), do: "-"
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp format_elapsed(milliseconds) do
    total_seconds = div(milliseconds, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    :io_lib.format("~2..0B:~2..0B", [minutes, seconds]) |> IO.iodata_to_binary()
  end

  defp format_event(nil), do: "waiting"

  defp format_event(event) do
    type = fetch(event, :type, "event")
    agent_id = fetch(event, :agent_id)

    if agent_id do
      "#{type}(#{agent_id})"
    else
      stringify(type)
    end
  end

  defp terminal_width do
    OwlIO.columns() || 96
  end

  defp canonical_type(agent_type) do
    AgentRegistry.canonical_type(agent_type)
  rescue
    _ -> agent_type
  end
end
