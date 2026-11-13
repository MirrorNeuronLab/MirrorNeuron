defmodule MirrorNeuron.Runtime.StableJob.Records do
  @moduledoc "Definition revisions and state/owner guards shared by lifecycle operations."

  alias MirrorNeuron.Runtime.JobResponse
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Persistence.RedisStore

  def increment_revision(definition) do
    Map.update(definition, "revision", 1, &(&1 + 1))
  end

  def persist_and_reconcile(job_id, definition) do
    case RedisStore.persist_job_definition(job_id, definition) do
      {:ok, saved} = result ->
        _ = JobResponse.definition_changed(saved)
        result

      error ->
        error
    end
  end

  def ensure_revision(_definition, nil), do: :ok

  def ensure_revision(_definition, 0), do: :ok

  def ensure_revision(definition, expected) when is_integer(expected) do
    if definition["revision"] == expected,
      do: :ok,
      else: {:error, :revision_mismatch}
  end

  def ensure_revision(_definition, _expected), do: {:error, :invalid_revision}

  def ensure_active(%{"status" => "active"}), do: :ok

  def ensure_active(_definition), do: {:error, :job_not_active}

  def ensure_mutable(%{"status" => status})
      when status in ["relocating", "relocated", "relocation_staged"],
      do: {:error, :job_relocation_in_progress}

  def ensure_mutable(_), do: :ok

  # Mutable file-backed data is node-affine. Transfer/backup may move ownership
  # explicitly later; a scheduler must not silently execute it elsewhere.

  def ensure_owner_node(%{"owner_node" => owner}) do
    if to_string(NodeAdapter.self()) == owner,
      do: :ok,
      else: {:error, {:job_data_owner_unavailable, owner}}
  end
end
