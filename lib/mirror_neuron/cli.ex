defmodule MirrorNeuron.CLI do
  require Logger

  alias MirrorNeuron.AgentRegistry

  def main(args) do
    configure_logger(args)
    maybe_start_distribution()
    Application.ensure_all_started(:mirror_neuron)

    case args do
      ["server"] ->
        IO.puts("MirrorNeuron runtime node is running on #{Node.self()}")

        receive do
        end

      ["validate", job_path] ->
        job_path
        |> MirrorNeuron.validate_manifest()
        |> print_manifest_validation()

      ["run", job_path | rest] ->
        run_job(job_path, parse_run_options(rest))

      ["inspect", "job", job_id] ->
        print_result(MirrorNeuron.inspect_job(job_id))

      ["inspect", "agents", job_id] ->
        print_result(MirrorNeuron.inspect_agents(job_id))

      ["inspect", "nodes"] ->
        output(MirrorNeuron.inspect_nodes())

      ["events", job_id] ->
        print_result(MirrorNeuron.events(job_id))

      ["pause", job_id] ->
        print_result(MirrorNeuron.pause(job_id))

      ["resume", job_id] ->
        print_result(MirrorNeuron.resume(job_id))

      ["cancel", job_id] ->
        print_result(MirrorNeuron.cancel(job_id))

      ["send", job_id, agent_id, message_json] ->
        case Jason.decode(message_json) do
          {:ok, payload} -> print_result(MirrorNeuron.send_message(job_id, agent_id, payload))
          {:error, error} -> abort("invalid JSON payload: #{Exception.message(error)}")
        end

      _ ->
        usage()
    end
  end

  defp parse_run_options(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [json: :boolean, timeout: :integer, no_await: :boolean]
      )

    [
      await: not Keyword.get(opts, :no_await, false),
      timeout: Keyword.get(opts, :timeout, :infinity),
      json: Keyword.get(opts, :json, false)
    ]
  end

  defp run_job(job_path, opts) do
    with {:ok, bundle} <- MirrorNeuron.validate_manifest(job_path),
         {:ok, job_id} <- MirrorNeuron.run_manifest(job_path, Keyword.put(opts, :await, false)) do
      cond do
        not Keyword.get(opts, :await, false) ->
          output(%{ok: true, job_id: job_id}, opts)

        Keyword.get(opts, :json, false) ->
          case MirrorNeuron.wait_for_job(job_id, Keyword.get(opts, :timeout, :infinity)) do
            {:ok, job} ->
              output(
                %{
                  ok: true,
                  job_id: job_id,
                  status: job["status"],
                  result: Map.get(job, "result")
                },
                opts
              )

            {:error, reason} ->
              abort(reason)
          end

        true ->
          case track_job_progress(job_id, bundle.manifest, Keyword.get(opts, :timeout, :infinity)) do
            {:ok, job} ->
              print_human_run_summary(job_id, job)

            {:error, reason} ->
              abort(reason)
          end
      end
    else
      {:error, reason} ->
        abort(reason)
    end
  end

  defp track_job_progress(job_id, manifest, timeout) do
    started_at = System.monotonic_time(:millisecond)
    loop_progress(job_id, manifest, timeout, started_at, 0)
  end

  defp loop_progress(job_id, manifest, timeout, started_at, tick) do
    job = fetch_job_snapshot(job_id)
    events = fetch_events(job_id)
    metrics = build_progress_metrics(events, manifest)

    render_progress_line(job_id, job, metrics, started_at, tick)

    case job do
      %{"status" => status} when status in ["completed", "failed", "cancelled"] ->
        clear_progress_line()
        {:ok, job}

      _ ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        if timeout != :infinity and elapsed > timeout do
          clear_progress_line()
          {:error, "timed out waiting for job #{job_id}"}
        else
          Process.sleep(200)
          loop_progress(job_id, manifest, timeout, started_at, tick + 1)
        end
    end
  end

  defp fetch_job_snapshot(job_id) do
    case MirrorNeuron.inspect_job(job_id) do
      {:ok, job} -> job
      {:error, _reason} -> %{"status" => "starting"}
    end
  end

  defp fetch_events(job_id) do
    case MirrorNeuron.events(job_id) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  end

  defp build_progress_metrics(events, manifest) do
    sandbox_total =
      Enum.count(manifest.nodes, &(AgentRegistry.canonical_type(&1.agent_type) == "executor"))

    collected = latest_aggregator_count(events)
    sandbox_done = Enum.count(events, &(&1["type"] == "sandbox_job_completed"))
    lease_requested = Enum.count(events, &(&1["type"] == "executor_lease_requested"))
    lease_acquired = Enum.count(events, &(&1["type"] == "executor_lease_acquired"))
    lease_released = Enum.count(events, &(&1["type"] == "executor_lease_released"))
    total_events = length(events)
    expected_results = expected_results(manifest, sandbox_total)

    %{
      sandbox_total: sandbox_total,
      sandbox_done: sandbox_done,
      leases_running: max(lease_acquired - lease_released, 0),
      leases_waiting: max(lease_requested - lease_acquired, 0),
      collected: collected,
      total_events: total_events,
      expected_results: expected_results,
      last_event: last_notable_event(events)
    }
  end

  defp latest_aggregator_count(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(0, fn event ->
      if event["type"] in ["aggregator_received", "collector_received"] do
        get_in(event, ["payload", "count"]) || 0
      end
    end)
  end

  defp expected_results(manifest, sandbox_total) do
    manifest.nodes
    |> Enum.find_value(sandbox_total, fn node ->
      if AgentRegistry.canonical_type(node.agent_type) == "aggregator" do
        Map.get(node.config, "complete_after")
      end
    end)
  end

  defp last_notable_event(events) do
    events
    |> Enum.reverse()
    |> Enum.find(fn event ->
      event["type"] not in ["agent_message_received", "aggregator_received", "collector_received"]
    end)
  end

  defp render_progress_line(job_id, job, metrics, started_at, tick) do
    spinner = Enum.at(["|", "/", "-", "\\"], rem(tick, 4))
    status = Map.get(job, "status", "starting")
    elapsed = format_elapsed(System.monotonic_time(:millisecond) - started_at)
    last_event = format_event(metrics.last_event)

    line =
      "#{spinner} job=#{job_id} status=#{status} elapsed=#{elapsed} " <>
        "events=#{metrics.total_events} collected=#{metrics.collected}/#{metrics.expected_results} " <>
        "leases=running:#{metrics.leases_running} waiting:#{metrics.leases_waiting} " <>
        "sandboxes=#{metrics.sandbox_done}/#{metrics.sandbox_total} last=#{last_event}"

    IO.write("\r" <> String.pad_trailing(line, 160))
  end

  defp clear_progress_line do
    IO.write("\r" <> String.duplicate(" ", 160) <> "\r")
  end

  defp format_elapsed(milliseconds) do
    total_seconds = div(milliseconds, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    :io_lib.format("~2..0B:~2..0B", [minutes, seconds]) |> IO.iodata_to_binary()
  end

  defp format_event(nil), do: "waiting"

  defp format_event(event) do
    type = event["type"]
    agent_id = event["agent_id"]

    if agent_id do
      "#{type}(#{agent_id})"
    else
      to_string(type)
    end
  end

  defp print_human_run_summary(job_id, job) do
    IO.puts("Job #{job_id} finished with status #{job["status"]}")

    if result = Map.get(job, "result") do
      IO.puts(format_human(result))
    end
  end

  defp print_manifest_validation({:ok, bundle}) do
    manifest = bundle.manifest

    output(%{
      ok: true,
      job_path: bundle.root_path,
      graph_id: manifest.graph_id,
      nodes: Enum.map(manifest.nodes, & &1.node_id),
      entrypoints: manifest.entrypoints
    })
  end

  defp print_manifest_validation({:error, reason}), do: abort(reason)

  defp print_result({:ok, value}), do: output(value)
  defp print_result({:error, reason}), do: abort(reason)

  defp output(value, opts \\ []) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(value, pretty: true))
    else
      IO.puts(format_human(value))
    end
  end

  defp format_human(value) when is_binary(value), do: value
  defp format_human(value), do: inspect(value, pretty: true, limit: :infinity)

  defp abort(reason) do
    IO.puts(:stderr, "error: #{format_reason(reason)}")
    System.halt(1)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_list(reason), do: Enum.join(reason, "; ")
  defp format_reason(reason), do: inspect(reason, pretty: true)

  defp usage do
    IO.puts("""
    mirror_neuron server
    mirror_neuron validate <job-folder>
    mirror_neuron run <job-folder> [--json] [--timeout <ms>] [--no-await]
    mirror_neuron inspect job <job_id>
    mirror_neuron inspect agents <job_id>
    mirror_neuron inspect nodes
    mirror_neuron events <job_id>
    mirror_neuron pause <job_id>
    mirror_neuron resume <job_id>
    mirror_neuron cancel <job_id>
    mirror_neuron send <job_id> <agent_id> <message.json>
    """)
  end

  defp configure_logger(args) do
    if args != ["server"] do
      Application.put_env(:logger, :level, :warning)
      Application.put_env(:logger, :default_handler, level: :warning)
      Logger.configure(level: :warning)
      :logger.set_primary_config(:level, :warning)
    end
  end

  defp maybe_start_distribution do
    node_name = System.get_env("MIRROR_NEURON_NODE_NAME")
    cookie = System.get_env("MIRROR_NEURON_COOKIE")

    cond do
      Node.alive?() ->
        :ok

      is_nil(node_name) or node_name == "" ->
        :ok

      true ->
        {:ok, _pid} = Node.start(String.to_atom(node_name), :longnames)

        if cookie && cookie != "" do
          Node.set_cookie(String.to_atom(cookie))
        end

        connect_configured_cluster_nodes(node_name)

        :ok
    end
  end

  defp connect_configured_cluster_nodes(self_node_name) do
    "MIRROR_NEURON_CLUSTER_NODES"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.reject(&(&1 == self_node_name))
    |> Enum.each(fn peer ->
      Node.connect(String.to_atom(peer))
    end)
  end
end
