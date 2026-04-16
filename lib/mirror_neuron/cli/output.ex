defmodule MirrorNeuron.CLI.Output do
  alias MirrorNeuron.CLI.UI

  def maybe_print_banner(command, subtitle) do
    if UI.interactive?() do
      UI.puts(UI.banner(command, subtitle))
    end
  end

  def maybe_print_section(title, details \\ nil) do
    if UI.interactive?() do
      UI.puts(UI.section(title, details))
    end
  end

  def print_manifest_validation({:ok, bundle}) do
    if UI.interactive?() do
      UI.puts(UI.manifest_summary(bundle))
    else
      manifest = bundle.manifest

      output(%{
        ok: true,
        job_path: bundle.root_path,
        graph_id: manifest.graph_id,
        nodes: Enum.map(manifest.nodes, & &1.node_id),
        entrypoints: manifest.entrypoints
      })
    end
  end

  def print_manifest_validation({:error, reason}), do: abort(reason)

  def print_run_submission(job_id, manifest, opts) do
    if interactive_output?(opts) do
      UI.puts(UI.run_started(job_id, manifest))
    end
  end

  def print_detached_run(job_id, opts) do
    if interactive_output?(opts) do
      UI.puts(UI.non_await_hint(job_id))
    else
      output(%{ok: true, job_id: job_id}, opts)
    end
  end

  def print_human_run_summary(job_id, job, opts) do
    if interactive_output?(opts) do
      UI.puts(UI.job_summary(job_id, job))
    else
      IO.puts("Job #{job_id} finished with status #{job["status"]}")

      if result = Map.get(job, "result") do
        IO.puts(format_human(result))
      end
    end
  end

  def print_job_result({:ok, value}) do
    if UI.interactive?(), do: UI.puts(UI.job_details(value)), else: output(value)
  end

  def print_job_result({:error, reason}), do: abort(reason)

  def print_agents_result({:ok, agents}) do
    if UI.interactive?(), do: UI.puts(UI.agents_table(agents)), else: output(agents)
  end

  def print_agents_result({:error, reason}), do: abort(reason)

  def print_events_result({:ok, events}) do
    if UI.interactive?(), do: UI.puts(UI.events_table(events)), else: output(events)
  end

  def print_events_result({:error, reason}), do: abort(reason)

  def print_nodes(nodes) do
    if UI.interactive?(), do: UI.puts(UI.nodes_table(nodes)), else: output(nodes)
  end

  def print_result({:ok, value}), do: output(value)
  def print_result({:error, reason}), do: abort(reason)

  def output(value, opts \\ []) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(value, pretty: true))
    else
      if UI.interactive?() and is_map(value) do
        UI.puts(UI.box("Output", inspect(value, pretty: true, limit: :infinity)))
      else
        IO.puts(format_human(value))
      end
    end
  end

  def abort(reason) do
    if UI.interactive?() do
      UI.puts(UI.error_box(format_reason(reason)), :stderr)
    else
      IO.puts(:stderr, "error: #{format_reason(reason)}")
    end

    System.halt(1)
  end

  def usage do
    maybe_print_banner(:inspect, "Command reference")

    if UI.interactive?() do
      UI.puts(UI.usage_screen())
    else
      IO.puts("""
      mn standalone-start
      mn cluster start --node-id <id> --bind <ip:port> [--data-dir <dir>] [--join <seeds>]
      mn cluster join --node-id <id> --bind <ip:port> --seeds <seeds>
      mn cluster discover --seeds <seeds>
      mn cluster status
      mn cluster nodes
      mn cluster leave --node-id <id>
      mn cluster rebalance
      mn cluster elect-leader
      mn cluster health
      mn cluster reload --node-id <id>
      mn validate <job-folder>
      mn run <job-folder> [--json] [--timeout <ms>] [--no-await]
      mn monitor [--json] [--running-only] [--limit <n>]
      mn job list [--all]
      mn job inspect <job_id>
      mn job agents <job_id>
      mn job events <job_id>
      mn job pause <job_id>
      mn job resume <job_id>
      mn job cancel <job_id>
      mn job cleanup [--all]
      mn job send <job_id> <agent_id> <message.json>
      mn node list
      mn bundle check <bundle_id>
      mn bundle reload <bundle_id>
      mn node add <node_name>
      mn node remove <node_name>

      Flags:
        -v, --verbose   Show warnings in addition to errors
        --json          Emit machine-readable JSON where supported
        --no-await      Submit a job and return immediately
        --timeout <ms>  Override wait timeout for blocking run commands
        --all           Show terminal jobs in `job list` (default is live jobs only)
      """)
    end
  end

  defp interactive_output?(opts), do: not Keyword.get(opts, :json, false) and UI.interactive?()

  defp format_human(value) when is_binary(value), do: value
  defp format_human(value), do: inspect(value, pretty: true, limit: :infinity)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_list(reason), do: Enum.join(reason, "; ")
  defp format_reason(reason), do: inspect(reason, pretty: true)
end
