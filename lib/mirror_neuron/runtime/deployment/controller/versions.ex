defmodule MirrorNeuron.Runtime.DeploymentController.Versions do
  @moduledoc "Selects rollback revisions and loads their durable executable definitions."

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Persistence.RedisStore

  def rollback_version(deployment, opts) do
    deployment_key = deployment["deployment_key"]
    requested = Keyword.get(opts, :version) || Keyword.get(opts, :tag)

    with {:ok, versions} <- RedisStore.list_job_versions(deployment_key) do
      version =
        cond do
          is_nil(requested) ->
            versions
            |> Enum.filter(&(&1["stable"] == true))
            |> Enum.reject(&(&1["version"] == deployment["current_version"]))
            |> List.last()

          Keyword.has_key?(opts, :tag) ->
            Enum.find(versions, &(&1["tag"] == requested))

          true ->
            Enum.find(versions, &(to_string(&1["version"]) == to_string(requested)))
        end

      case version do
        nil -> {:error, "no rollback target found for deployment #{deployment_key}"}
        record -> {:ok, record}
      end
    end
  end

  def bundle_or_manifest_from_version(%{
        "manifest_ref" => %{"bundle_fingerprint" => fingerprint}
      })
      when is_binary(fingerprint) and fingerprint != "" do
    case Archive.load(fingerprint) do
      {:ok, bundle} -> {:ok, bundle}
      {:error, _reason} = error -> error
    end
  end

  def bundle_or_manifest_from_version(%{"manifest" => manifest}) when is_map(manifest),
    do: {:ok, manifest}

  def bundle_or_manifest_from_version(_version),
    do: {:error, "version does not include a manifest"}

  def next_version(deployment_key) do
    case RedisStore.list_job_versions(deployment_key) do
      {:ok, []} ->
        "1"

      {:ok, versions} ->
        versions
        |> Enum.map(&version_integer(&1["version"]))
        |> Enum.max()
        |> Kernel.+(1)
        |> to_string()

      _ ->
        "1"
    end
  end

  defp version_integer(version) do
    case Integer.parse(to_string(version)) do
      {integer, ""} -> integer
      _ -> 0
    end
  end
end
