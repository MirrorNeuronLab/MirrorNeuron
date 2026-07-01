defmodule MirrorNeuron.ModelAccess.ServiceResolver do
  @moduledoc false

  alias MirrorNeuron.ServiceRegistry

  def register(service), do: ServiceRegistry.register(service)
  def register_many(services), do: ServiceRegistry.register_many(services)
  def list(opts \\ []), do: ServiceRegistry.list(opts)
  def resolve(name, opts \\ []), do: ServiceRegistry.resolve(name, opts)

  def resolve_docker_model_runner(tags \\ []) do
    opts =
      tags
      |> List.wrap()
      |> Enum.reduce([], fn tag, acc -> Keyword.update(acc, :tags, [tag], &[tag | &1]) end)

    resolve("docker-model-runner", opts)
  end
end
