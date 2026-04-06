defmodule MirrorNeuron.Bundle.Source do
  @moduledoc """
  Behavior for retrieving bundle paths and reading bundles.
  """

  @callback list_bundles(root_path :: String.t()) :: [String.t()]
end
