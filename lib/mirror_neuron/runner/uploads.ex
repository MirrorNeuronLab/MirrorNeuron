defmodule MirrorNeuron.Runner.Uploads do
  @moduledoc false

  alias MirrorNeuron.Artifacts.{BlobRef, Resolver}

  def materialize_artifacts(source, target, config, opts) do
    payloads_path = Keyword.get(opts, :payloads_path)

    with refs when refs != [] <- artifact_refs(config),
         {:ok, prefix} <- payload_prefix(source, payloads_path) do
      Resolver.materialize_payload_refs(refs, prefix, target, job_id: Keyword.get(opts, :job_id))
    else
      _ -> :not_found
    end
  end

  def artifact_refs(config) when is_map(config) do
    config
    |> Map.get("__artifact_refs", [])
    |> BlobRef.collect()
  end

  def artifact_refs(_config), do: []

  defp payload_prefix(_source, nil), do: {:error, :missing_payloads_path}

  defp payload_prefix(source, payloads_path) do
    payloads_root = Path.expand(payloads_path)
    source = Path.expand(source)

    if source == payloads_root or String.starts_with?(source, payloads_root <> "/") do
      relative = Path.relative_to(source, payloads_root) |> BlobRef.normalize_payload_path()
      {:ok, relative || ""}
    else
      {:error, :outside_payloads}
    end
  end
end
