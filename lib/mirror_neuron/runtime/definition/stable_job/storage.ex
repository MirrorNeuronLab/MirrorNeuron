defmodule MirrorNeuron.Runtime.StableJob.Storage do
  @moduledoc "Validates persistent data declarations and resolves bundle-relative seed directories."

  alias MirrorNeuron.Runtime.StableJob.Values

  def storage_declarations(bundle, explicit) do
    with {:ok, metadata} <- storage_map(bundle.manifest.metadata),
         {:ok, declared} <- storage_map(Map.get(metadata, "job_data", %{})),
         {:ok, explicit} <- storage_map(explicit),
         storage <- Map.merge(declared, explicit),
         resources <- Map.get(storage, "resources", []),
         true <- is_list(resources) and Enum.all?(resources, &valid_resource?/1) do
      {:ok, Map.put(storage, "resources", resources)}
    else
      _ -> {:error, :invalid_job_data_declarations}
    end
  end

  defp storage_map(nil), do: {:ok, %{}}
  defp storage_map(value) when is_map(value), do: {:ok, Values.stringify(value)}
  defp storage_map(_value), do: {:error, :invalid_job_data_declarations}

  defp valid_resource?(resource) when is_map(resource) do
    name = Map.get(resource, "name")
    path = Map.get(resource, "path", name)
    access = Map.get(resource, "access", "read_write")

    valid_relative_path?(name) and valid_relative_path?(path) and
      access in ["read", "read_only", "ro", "read_write", "write", "rw"] and
      valid_seed?(Map.get(resource, "seed"))
  end

  defp valid_resource?(_resource), do: false

  defp valid_seed?(nil), do: true

  defp valid_seed?(seed) when is_binary(seed), do: String.starts_with?(seed, "@/")

  defp valid_seed?(_seed), do: false

  defp valid_relative_path?(path) when is_binary(path) do
    Path.type(path) == :relative and path != "" and
      Enum.all?(Path.split(path), &Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, &1))
  end

  defp valid_relative_path?(_path), do: false

  def seed_paths(bundle, storage) do
    resources = Map.get(Values.stringify(storage || %{}), "resources", [])

    Enum.reduce_while(resources, {:ok, %{}}, fn resource, {:ok, seeds} ->
      case Map.get(resource, "seed") do
        nil ->
          {:cont, {:ok, seeds}}

        "@/" <> relative ->
          with root when is_binary(root) <- bundle.root_path,
               source <- Path.expand(relative, root),
               true <- inside_bundle?(source, root),
               true <- File.dir?(source) do
            target = Map.get(resource, "path", resource["name"])
            {:cont, {:ok, Map.put(seeds, target, source)}}
          else
            _ -> {:halt, {:error, {:invalid_job_data_seed, resource["name"]}}}
          end
      end
    end)
  end

  defp inside_bundle?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  def default_job_data_access(storage) do
    storage
    |> Values.stringify()
    |> Map.get("resources", [])
    |> Enum.map(&Map.get(&1, "access", "read_write"))
    |> Enum.all?(&(&1 in ["read", "read_only", "ro"]))
    |> if(do: "read", else: "read_write")
  end
end
