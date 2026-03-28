defmodule MirrorNeuron.MonitorCLI do
  require Logger

  alias MirrorNeuron.CLI.UI
  alias MirrorNeuron.Monitor

  def main(args) do
    configure_logger()
    Application.ensure_all_started(:mirror_neuron)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          refresh_ms: :integer,
          limit: :integer,
          running_only: :boolean,
          json: :boolean,
          help: :boolean
        ]
      )

    cond do
      Keyword.get(opts, :help, false) ->
        usage()

      Keyword.get(opts, :json, false) ->
        print_json(opts)

      true ->
        dashboard_loop(opts)
    end
  end

  defp dashboard_loop(opts) do
    case Monitor.cluster_overview(
           limit: Keyword.get(opts, :limit, 20),
           include_terminal: not Keyword.get(opts, :running_only, false)
         ) do
      {:ok, overview} ->
        clear_screen()
        UI.puts(UI.banner(:inspect, "Platform monitor"))
        UI.puts(render_overview(overview))

        case prompt("monitor> [number=open, r=refresh, q=quit] ") do
          "q" ->
            :ok

          "r" ->
            dashboard_loop(opts)

          "" ->
            dashboard_loop(opts)

          value ->
            open_job(value, overview["jobs"], opts)
        end

      {:error, reason} ->
        UI.puts(UI.error_box(reason), :stderr)
    end
  end

  defp open_job(selection, jobs, opts) do
    case Integer.parse(selection) do
      {index, ""} ->
        case Enum.at(jobs, index - 1) do
          nil ->
            dashboard_loop(opts)

          job ->
            job_loop(job["job_id"], opts)
        end

      _ ->
        matching =
          Enum.find(jobs, fn job ->
            job["job_id"] == selection
          end)

        if matching do
          job_loop(matching["job_id"], opts)
        else
          dashboard_loop(opts)
        end
    end
  end

  defp job_loop(job_id, opts) do
    case Monitor.job_details(job_id) do
      {:ok, details} ->
        clear_screen()
        UI.puts(UI.banner(:inspect, "Job #{job_id}"))
        UI.puts(render_job_details(details))

        case prompt("job> [b=back, r=refresh, q=quit] ") do
          "q" -> :ok
          "b" -> dashboard_loop(opts)
          "r" -> job_loop(job_id, opts)
          "" -> job_loop(job_id, opts)
          _ -> job_loop(job_id, opts)
        end

      {:error, reason} ->
        UI.puts(UI.error_box(reason), :stderr)
        dashboard_loop(opts)
    end
  end

  defp render_overview(%{"nodes" => nodes, "jobs" => jobs}) do
    body = [
      UI.section("Cluster"),
      "\n",
      nodes_table(nodes),
      "\n\n",
      UI.section("Jobs", "#{length(jobs)} visible"),
      "\n",
      jobs_table(jobs),
      "\n\n",
      UI.box(
        "Tips",
        [
          "Enter a job number to open details.\n",
          "Use job id directly if you already know it.\n",
          "Pass `--running-only` to focus on live work."
        ],
        border_tag: :yellow,
        title_tag: :yellow
      )
    ]

    UI.box("MirrorNeuron Monitor", body, border_tag: :cyan)
  end

  defp render_job_details(%{
         "job" => job,
         "summary" => summary,
         "agents" => agents,
         "sandboxes" => sandboxes,
         "recent_events" => recent_events
       }) do
    body = [
      UI.job_details(job),
      "\n\n",
      UI.section("Execution"),
      "\n",
      execution_box(summary, sandboxes),
      "\n\n",
      UI.section("Sandboxes", "#{length(sandboxes)} total"),
      "\n",
      sandboxes_table(sandboxes),
      "\n\n",
      UI.section("Agents", "#{length(agents)} total"),
      "\n",
      agents_table(agents),
      "\n\n",
      UI.section("Recent events"),
      "\n",
      recent_events_box(recent_events)
    ]

    UI.box("Job Monitor", body, border_tag: :green, title_tag: :green)
  end

  defp jobs_table(jobs) do
    rows =
      jobs
      |> Enum.with_index(1)
      |> Enum.map(fn {job, index} ->
        [
          Integer.to_string(index),
          job["status"] || "-",
          shorten(job["graph_id"] || "-", 24),
          boxes_summary(job["nodes"] || []),
          Integer.to_string(length(job["sandbox_names"] || [])),
          shorten(job["last_event"] || "-", 28)
        ]
      end)

    table(["#", "status", "graph", "boxes", "sandboxes", "last event"], rows)
  end

  defp nodes_table(nodes) do
    rows =
      Enum.map(nodes, fn node ->
        default_pool =
          Map.get(node[:executor_pools] || node["executor_pools"] || %{}, "default") ||
            Map.get(node[:executor_pools] || node["executor_pools"] || %{}, :default) || %{}

        [
          to_string(node[:name] || node["name"]),
          if(node[:self?] || node["self?"], do: "yes", else: "no"),
          Integer.to_string(length(node[:connected_nodes] || node["connected_nodes"] || [])),
          "#{default_pool[:available] || default_pool["available"] || 0}/#{default_pool[:capacity] || default_pool["capacity"] || 0}",
          Integer.to_string(default_pool[:queued] || default_pool["queued"] || 0)
        ]
      end)

    table(["node", "self", "links", "free", "queued"], rows)
  end

  defp agents_table(agents) do
    rows =
      Enum.map(agents, fn agent ->
        [
          agent["agent_id"] || "-",
          agent["agent_type"] || "-",
          agent["status"] || "-",
          shorten(agent["assigned_node"] || "-", 22),
          shorten(agent["sandbox_name"] || "-", 24),
          Integer.to_string(agent["processed_messages"] || 0)
        ]
      end)

    table(["agent", "type", "status", "node", "sandbox", "processed"], rows)
  end

  defp sandboxes_table(sandboxes) do
    rows =
      Enum.map(sandboxes, fn sandbox ->
        [
          sandbox["agent_id"] || "-",
          shorten(sandbox["sandbox_name"] || "-", 42),
          sandbox["pool"] || "-",
          to_string(sandbox["exit_code"] || "-")
        ]
      end)

    table(["agent", "sandbox", "pool", "exit"], rows)
  end

  defp execution_box(summary, sandboxes) do
    lines = [
      UI.status_line("Status", summary["status"] || "-", status_color(summary["status"])),
      "\n",
      UI.status_line("Nodes", boxes_summary(summary["nodes"] || [])),
      "\n",
      UI.status_line(
        "Executors",
        "#{summary["active_executors"] || 0}/#{summary["executor_count"] || 0} active"
      ),
      "\n",
      UI.status_line("Sandboxes", Integer.to_string(length(sandboxes))),
      "\n",
      UI.status_line("Last", shorten(summary["last_event"] || "-", 48))
    ]

    UI.box("Runtime Footprint", lines, border_tag: :yellow, title_tag: :yellow)
  end

  defp recent_events_box(events) do
    rows =
      events
      |> Enum.take(12)
      |> Enum.map(fn event ->
        [
          Map.get(event, "timestamp", "-"),
          Map.get(event, "type", "-"),
          Map.get(event, "agent_id", "-"),
          event_payload(event)
        ]
      end)

    table(["timestamp", "type", "agent", "payload"], rows)
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
        header |> String.upcase() |> String.pad_trailing(Enum.at(widths, index))
      end)
      |> Enum.join("  ")

    separator =
      widths
      |> Enum.map(&String.duplicate("-", &1))
      |> Enum.join("  ")

    body =
      rows
      |> Enum.map(fn row ->
        row
        |> Enum.with_index()
        |> Enum.map(fn {value, index} -> String.pad_trailing(value, Enum.at(widths, index)) end)
        |> Enum.join("  ")
      end)
      |> Enum.join("\n")

    UI.box("Table", [header_line, "\n", separator, "\n", body],
      border_tag: :light_black,
      title_tag: :light_black
    )
  end

  defp print_json(opts) do
    case Monitor.cluster_overview(
           limit: Keyword.get(opts, :limit, 20),
           include_terminal: not Keyword.get(opts, :running_only, false)
         ) do
      {:ok, overview} -> IO.puts(Jason.encode!(overview, pretty: true))
      {:error, reason} -> IO.puts(:stderr, inspect(reason))
    end
  end

  defp usage do
    UI.puts(UI.banner(:inspect, "Platform monitor"))

    UI.puts(
      UI.box(
        "Usage",
        [
          "mirror_neuron_monitor [--running-only] [--limit 20] [--refresh-ms 2000]\n",
          "mirror_neuron_monitor --json\n\n",
          "For cluster mode, set the same MIRROR_NEURON_* env vars you use with control nodes."
        ],
        border_tag: :cyan
      )
    )
  end

  defp prompt(label) do
    IO.gets(label)
    |> case do
      nil -> "q"
      value -> String.trim(value)
    end
  end

  defp clear_screen do
    IO.write(IO.ANSI.home() <> IO.ANSI.clear())
  end

  defp event_payload(event) do
    event
    |> Map.get("payload", %{})
    |> inspect(limit: 3, pretty: false)
    |> String.replace("\n", " ")
    |> String.slice(0, 56)
  end

  defp boxes_summary([]), do: "-"
  defp boxes_summary(nodes), do: "#{length(nodes)} box(es)"

  defp shorten(nil, _max), do: "-"
  defp shorten(value, max) when is_binary(value) and byte_size(value) <= max, do: value

  defp shorten(value, max) when is_binary(value) and max > 3,
    do: String.slice(value, 0, max - 3) <> "..."

  defp shorten(value, _max), do: to_string(value)

  defp status_color("completed"), do: :green
  defp status_color("failed"), do: :red
  defp status_color("cancelled"), do: :yellow
  defp status_color("running"), do: :cyan
  defp status_color("pending"), do: :yellow
  defp status_color(_), do: :cyan

  defp configure_logger do
    :logger.set_primary_config(:level, :warning)
    :logger.set_handler_config(:default, :level, :warning)
    Logger.configure(level: :warning)
    Logger.configure_backend(:default, level: :warning)
  end
end
