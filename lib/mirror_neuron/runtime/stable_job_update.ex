defmodule MirrorNeuron.Runtime.StableJobUpdate do
  @moduledoc false

  @mutable_fields ~w(resolved_configuration schedules storage job_name status)

  # Archive has its own gated operation, which stops the responder and pauses
  # schedules. Reactivation changes only the definition; runs stay terminal and
  # schedules stay paused until the caller explicitly starts or enables them.
  def apply(definition, attrs) do
    case Map.fetch(attrs, "status") do
      :error -> {:ok, Map.merge(definition, Map.take(attrs, @mutable_fields))}
      {:ok, "active"} -> {:ok, Map.merge(definition, Map.take(attrs, @mutable_fields))}
      _ -> {:error, :invalid_job_update}
    end
  end
end
