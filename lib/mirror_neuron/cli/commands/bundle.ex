defmodule MirrorNeuron.CLI.Commands.Bundle do
  alias MirrorNeuron.Bundle.Manager
  alias MirrorNeuron.CLI.Output

  def run(["reload", bundle_id]) do
    case Manager.reload(bundle_id, "cli_manual") do
      {:ok, resp} ->
        Owl.IO.puts([Owl.Data.tag("Bundle Reload Status: #{bundle_id}", :cyan)])
        Owl.IO.puts(["  Changed: ", inspect(resp.changed)])
        Owl.IO.puts(["  Reloaded: ", inspect(resp.reloaded)])
        Owl.IO.puts(["  Message: ", resp.message])

        if resp.changed do
          Owl.IO.puts(["  Previous Fingerprint: ", resp.previous_fingerprint])
          Owl.IO.puts(["  Current Fingerprint: ", resp.current_fingerprint])
        end

      {:error, :not_found} ->
        Output.abort("Bundle #{bundle_id} not found in manager.")

      {:error, reason} ->
        Output.abort("Failed to reload bundle: #{inspect(reason)}")
    end
  end

  def run(["check", bundle_id]) do
    case Manager.get_bundle(bundle_id) do
      {:ok, record} ->
        Owl.IO.puts([Owl.Data.tag("Bundle Check: #{bundle_id}", :cyan)])
        Owl.IO.puts(["  Path: ", record.path])
        Owl.IO.puts(["  Current Fingerprint: ", record.fingerprint])

        manifest = record.bundle_struct.manifest
        Owl.IO.puts(["  Reload Mode: ", manifest.reload.mode])

        if manifest.reload.mode == "interval" do
          Owl.IO.puts(["  Interval Seconds: ", to_string(manifest.reload.interval_seconds)])
        end

        Owl.IO.puts(["  Last Reloaded: ", record.last_reloaded])

      _ ->
        Output.abort("Bundle #{bundle_id} not found in manager.")
    end
  end

  def run(_) do
    Output.usage()
  end
end
