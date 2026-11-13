defmodule MirrorNeuron.OpenShellCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.OpenShellCase
    end
  end

  def logged_arg_after(log_path, flag) do
    log_path
    |> File.read!()
    |> String.split()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _other -> nil
    end)
  end
end
