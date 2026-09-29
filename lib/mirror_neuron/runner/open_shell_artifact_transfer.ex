defmodule MirrorNeuron.Runner.OpenShellArtifactTransfer do
  @moduledoc false
  alias MirrorNeuron.Runner.Result
  alias MirrorNeuron.Sandbox.OpenShellCLI

  def files(config, state, stage, manifest) do
    limits = config["artifact_handoff"]
    refs = manifest["references"]

    valid =
      is_list(refs) and length(refs) <= Map.get(limits, "max_files", 256) and
        Enum.all?(
          refs,
          &(is_integer(&1["size_bytes"]) and &1["size_bytes"] >= 0 and safe?(&1["path"]))
        ) and
        Enum.sum(Enum.map(refs, & &1["size_bytes"])) <= Map.get(limits, "max_bytes", 64_000_000)

    if valid do
      Enum.reduce_while(refs, :ok, fn ref, :ok ->
        file = Path.join([stage, "outputs", ref["path"]])
        target = Path.dirname(file)
        File.mkdir_p!(target)

        result =
          if verified?(file, ref),
            do: :ok,
            else: download(config, state, "outputs/" <> ref["path"], target, ref["size_bytes"])

        case result do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error,
       %{"phase" => "artifact_verification_failed", "error" => "invalid artifact path or quota"}}
    end
  end

  def download(config, state, source, target, max_bytes \\ 4_000_000, retries \\ 2) do
    executable =
      Map.get(
        config,
        "sandbox_cli",
        MirrorNeuron.Config.executable("MN_OPENSHELL_BIN", :openshell_bin)
      )

    args = [
      executable,
      "sandbox",
      "download",
      state["sandbox"]["sandbox_name"],
      Path.join(state["workspace"], source),
      target
    ]

    # Cap even a dishonest remote file before the downloader can fill owner storage.
    shell = "ulimit -f #{max(1, div(max_bytes + 1023, 1024))}; exec \"$@\""

    case System.cmd("bash", ["-c", shell, "artifact-download" | args],
           stderr_to_stdout: true,
           env: OpenShellCLI.command_env()
         ) do
      {_, 0} -> :ok
      {_, _} when retries > 0 -> download(config, state, source, target, max_bytes, retries - 1)
      {output, code} -> {:error, Result.sanitize(%{"exit_code" => code, "logs" => output})}
    end
  end

  defp verified?(file, ref) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(file),
         true <- size == ref["size_bytes"] do
      hash =
        File.stream!(file, 65_536)
        |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
          :crypto.hash_update(acc, chunk)
        end)
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      hash == ref["sha256"]
    else
      _ -> false
    end
  end

  defp safe?(path),
    do:
      is_binary(path) and Path.type(path) == :relative and
        not String.contains?(path, ["\\", "\0"]) and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
end
