defmodule MirrorNeuron.CLI.Commands.Run do
  alias MirrorNeuron.AgentRegistry
  alias MirrorNeuron.CLI.Output
  alias MirrorNeuron.CLI.UI

  def parse_options(args) do
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

  def run(job_path, opts) do
    Output.maybe_print_banner(:run, job_path)

    with {:ok, bundle} <- MirrorNeuron.validate_manifest(job_path),
         {:ok, job_id} <- MirrorNeuron.run_manifest(job_path, Keyword.put(opts, :await, false)) do
      Output.print_run_submission(job_id, bundle.manifest, opts)

      cond do
        not Keyword.get(opts, :await, false) ->
          Output.print_detached_run(job_id, opts)

        Keyword.get(opts, :json, false) ->
          case MirrorNeuron.wait_for_job(job_id, Keyword.get(opts, :timeout, :infinity)) do
            {:ok, job} ->
              Output.output(
                %{
                  ok: true,
                  job_id: job_id,
                  status: job["status"],
                  result: Map.get(job, "result")
                },
                opts
              )

            {:error, reason} ->
              Output.abort(reason)
          end

        true ->
          if :logger.get_primary_config().level != :info do
            Logger.configure(level: :error)
            :logger.set_primary_config(:level, :error)
          end

          case track_job_progress(job_id, bundle.manifest, Keyword.get(opts, :timeout, :infinity)) do
            {:ok, job} ->
              Output.print_human_run_summary(job_id, job, opts)

            {:error, reason} ->
              Output.abort(reason)
          end
      end
    else
      {:error, reason} ->
        Output.abort(reason)
    end
  end

  defp track_job_progress(job_id, manifest, timeout) do
    started_at = System.monotonic_time(:millisecond)

    UI.start_progress_screen(%{
      job_id: job_id,
      job: %{"status" => "starting"},
      metrics: %{
        collected: 0,
        expected_results: expected_results(manifest, 0),
        sandbox_done: 0,
        sandbox_total: 0,
        leases_running: 0,
        leases_waiting: 0,
        total_events: 0,
        last_event: nil
      },
      started_at: started_at,
      tick: 0
    })

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
    |> Enum.find_value(default_expected_results(manifest, sandbox_total), fn node ->
      if AgentRegistry.canonical_type(node.agent_type) == "aggregator" do
        Map.get(node.config, "complete_after") ||
          if(Map.get(node.config, "complete_on_message"), do: 1, else: nil)
      end
    end)
  end

  defp default_expected_results(manifest, sandbox_total) do
    if open_ended_manifest?(manifest) do
      nil
    else
      sandbox_total
    end
  end

  defp open_ended_manifest?(manifest) do
    has_explicit_completion? =
      Enum.any?(manifest.nodes, fn node ->
        config = Map.get(node, :config, %{})

        Map.get(config, "complete_on_message", false) or
          Map.get(config, "complete_job", false) or
          match?(value when is_integer(value) and value > 0, Map.get(config, "complete_after"))
      end)

    has_module_nodes? =
      Enum.any?(manifest.nodes, fn node ->
        AgentRegistry.canonical_type(node.agent_type) == "module"
      end)

    has_module_nodes? and not has_explicit_completion?
  end

  defp last_notable_event(events) do
    events
    |> Enum.reverse()
    |> Enum.find(fn event ->
      event["type"] not in ["agent_message_received", "aggregator_received", "collector_received"]
    end)
  end

  defp render_progress_line(job_id, job, metrics, started_at, tick) do
    if UI.interactive?() do
      UI.update_progress_screen(%{
        job_id: job_id,
        job: job,
        metrics: metrics,
        started_at: started_at,
        tick: tick
      })
    else
      spinner = Enum.at(["|", "/", "-", "\\"], rem(tick, 4))
      status = Map.get(job, "status", "starting")
      elapsed = format_elapsed(System.monotonic_time(:millisecond) - started_at)
      last_event = format_event(metrics.last_event)

      line =
        "#{spinner} job=#{job_id} status=#{status} elapsed=#{elapsed} " <>
          "events=#{metrics.total_events} results=#{format_result_progress(metrics)} " <>
          "leases=running:#{metrics.leases_running} waiting:#{metrics.leases_waiting} " <>
          "sandboxes=#{metrics.sandbox_done}/#{metrics.sandbox_total} last=#{last_event}"

      IO.write("\r" <> String.pad_trailing(line, 160))
    end
  end

  defp clear_progress_line do
    if UI.interactive?() do
      UI.clear_progress()
    else
      IO.write("\r" <> String.duplicate(" ", 160) <> "\r")
    end
  end

  defp format_elapsed(milliseconds) do
    total_seconds = div(milliseconds, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    :io_lib.format("~2..0B:~2..0B", [minutes, seconds]) |> IO.iodata_to_binary()
  end

  defp format_result_progress(%{collected: collected, expected_results: expected_results})
       when is_integer(expected_results) and expected_results > 0 do
    "#{collected}/#{expected_results}"
  end

  defp format_result_progress(%{collected: collected}), do: "#{collected} (open-ended)"

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
end
