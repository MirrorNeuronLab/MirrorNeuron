defmodule MirrorNeuron.JobBundle do
  alias MirrorNeuron.Manifest

  defstruct [
    :root_path,
    :manifest_path,
    :payloads_path,
    :manifest
  ]

  def load(%__MODULE__{} = bundle), do: {:ok, bundle}

  def load(%Manifest{} = manifest) do
    {:ok, %__MODULE__{manifest: manifest}}
  end

  def load(map) when is_map(map) do
    with {:ok, manifest} <- Manifest.load(map) do
      {:ok, %__MODULE__{manifest: manifest}}
    end
  end

  def load(path) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) ->
        load_from_directory(expanded)

      File.exists?(expanded) ->
        {:error, "expected a job folder, got file #{expanded}"}

      true ->
        case Jason.decode(path) do
          {:ok, decoded} -> load(decoded)
          {:error, error} -> {:error, Exception.message(error)}
        end
    end
  end

  defp load_from_directory(root_path) do
    manifest_path = Path.join(root_path, "manifest.json")
    payloads_path = Path.join(root_path, "payloads")

    cond do
      not File.exists?(manifest_path) ->
        {:error, "job folder is missing manifest.json: #{manifest_path}"}

      not File.dir?(payloads_path) ->
        {:error, "job folder is missing payloads/: #{payloads_path}"}

      true ->
        with {:ok, manifest} <- Manifest.load(manifest_path) do
          {:ok,
           %__MODULE__{
             root_path: root_path,
             manifest_path: manifest_path,
             payloads_path: payloads_path,
             manifest: manifest
           }}
        end
    end
  end
end
