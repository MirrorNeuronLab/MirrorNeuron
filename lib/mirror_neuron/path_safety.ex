defmodule MirrorNeuron.PathSafety do
  @moduledoc false

  def safe_relative_path?(path) when is_binary(path) do
    path = String.replace(path, "\\", "/")

    Path.type(path) == :relative and
      path not in ["", "."] and
      path
      |> String.split("/", trim: true)
      |> Enum.all?(&(&1 not in [".", ".."]))
  end

  def safe_relative_path?(_path), do: false

  def unsafe_relative_path?(path), do: not safe_relative_path?(path)
end
