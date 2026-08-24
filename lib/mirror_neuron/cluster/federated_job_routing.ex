defmodule MirrorNeuron.Cluster.FederatedJobRouting do
  @moduledoc false

  alias MirrorNeuron.Cluster.{FederationClient, FederationRegistry}

  @doc false
  def job_owner(job_id, dependencies \\ [])

  def job_owner(job_id, dependencies) when is_binary(job_id) do
    owner(
      job_id,
      local_lookup: Keyword.get(dependencies, :local_lookup, &MirrorNeuron.get_job/1),
      projection_owner:
        Keyword.get(dependencies, :projection_owner, &FederationRegistry.projection_owner/1),
      discover_owner:
        Keyword.get(dependencies, :discover_owner, &FederationClient.discover_job_owner/1)
    )
  end

  def job_owner(_job_id, _dependencies), do: nil

  @doc false
  def run_owner(run_id, dependencies \\ [])

  def run_owner(run_id, dependencies) when is_binary(run_id) do
    owner(
      run_id,
      local_lookup: Keyword.get(dependencies, :local_lookup, &MirrorNeuron.inspect_job/1),
      projection_owner:
        Keyword.get(dependencies, :projection_owner, &FederationRegistry.projection_owner/1),
      discover_owner:
        Keyword.get(dependencies, :discover_owner, &FederationClient.discover_run_owner/1)
    )
  end

  def run_owner(_run_id, _dependencies), do: nil

  defp owner(resource_id, dependencies) do
    case dependencies[:local_lookup].(resource_id) do
      {:ok, _resource} ->
        nil

      _missing ->
        dependencies[:projection_owner].(resource_id) ||
          dependencies[:discover_owner].(resource_id)
    end
  end
end
