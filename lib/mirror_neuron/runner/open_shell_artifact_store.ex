defmodule MirrorNeuron.Runner.OpenShellArtifactStore do
  @moduledoc false

  def helper_dir, do: Application.app_dir(:mirror_neuron, "priv/openshell_handoff")

  def call(base, operation, fields \\ %{}) do
    request = Map.merge(base, Map.put(fields, "op", operation))

    temporary =
      Path.join(System.tmp_dir!(), "mn-handoff-#{System.unique_integer([:positive])}.json")

    try do
      File.write!(temporary, Jason.encode!(request))

      case System.cmd("python3", [Path.join(helper_dir(), "store.py"), temporary],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, %{"ok" => value}} -> {:ok, value}
            _ -> {:error, %{"error" => "invalid artifact store response"}}
          end

        {output, _} ->
          case Jason.decode(output) do
            {:ok, error} -> {:error, error}
            _ -> {:error, %{"error" => "artifact store unavailable"}}
          end
      end
    after
      File.rm(temporary)
    end
  end
end
