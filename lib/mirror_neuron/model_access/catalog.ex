defmodule MirrorNeuron.ModelAccess.Catalog do
  @moduledoc false

  alias MirrorNeuron.ModelCatalog

  def load, do: ModelCatalog.load_catalog()
  def list_entries(catalog \\ ModelCatalog.load_catalog()), do: ModelCatalog.list_entries(catalog)

  def resolve(model, catalog \\ ModelCatalog.load_catalog()),
    do: ModelCatalog.resolve(model, catalog)

  def resolve!(model, catalog \\ ModelCatalog.load_catalog()),
    do: ModelCatalog.resolve!(model, catalog)

  def service_requirement(entry), do: ModelCatalog.service_requirement(entry)
  def service_instance(entry, node_name), do: ModelCatalog.service_instance(entry, node_name)
  def service_tags(entry), do: ModelCatalog.service_tags(entry)
end
