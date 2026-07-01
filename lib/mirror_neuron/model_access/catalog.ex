defmodule MirrorNeuron.ModelAccess.Catalog do
  @moduledoc false

  def load, do: %{}
  def list_entries(_catalog \\ %{}), do: []

  def resolve(_model, _catalog \\ %{}), do: {:error, :model_catalog_owned_by_sdk}

  def resolve!(model, _catalog \\ %{}) do
    raise ArgumentError,
          "model catalog resolution for #{inspect(model)} is owned by mn-python-sdk"
  end

  def service_requirement(_entry),
    do: raise(ArgumentError, "model service expansion is owned by mn-python-sdk")

  def service_instance(_entry, _node_name),
    do: raise(ArgumentError, "model service expansion is owned by mn-python-sdk")

  def service_tags(_entry),
    do: raise(ArgumentError, "model service expansion is owned by mn-python-sdk")
end
