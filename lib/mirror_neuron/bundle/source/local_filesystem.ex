defmodule MirrorNeuron.Bundle.Source.LocalFilesystem do
  @behaviour MirrorNeuron.Bundle.Source

  @impl true
  def list_bundles(root_path) do
    if File.dir?(root_path) do
      root_path
      |> File.ls!()
      |> Enum.map(&Path.join(root_path, &1))
      |> Enum.filter(fn path ->
        File.dir?(path) and File.exists?(Path.join(path, "manifest.json"))
      end)
    else
      []
    end
  end
end
