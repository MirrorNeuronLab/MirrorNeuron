defmodule MirrorNeuron.Persistence.RedisStore.Guards do
  @moduledoc "Lease epochs, cancellation fences and compact job guard records."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Values

  @doc false
  def validate_job_attempt_epoch(job_id, epoch) when is_integer(epoch) do
    validate_persisted_lease_epoch(job_id, epoch)
  end

  def validate_job_attempt_epoch(_job_id, nil), do: :ok

  def validate_job_attempt_epoch(_job_id, epoch),
    do: {:error, {:invalid_attempt_epoch, epoch}}

  def job_guard(job_id, job, mode \\ :durable) do
    guard = %{
      "job_id" => Values.field(job, "job_id") || job_id,
      "status" => Values.field(job, "status"),
      "attempt" => Values.field(job, "attempt", 0),
      "lease_epoch" => lease_epoch(job),
      "cancellation_fence_epoch" =>
        Values.parse_integer(Values.field(job, "cancellation_fence_epoch")),
      "finalization_id" => Values.field(job, "finalization_id"),
      "updated_at" => Values.field(job, "updated_at")
    }

    # A partial status projection cannot change a v2 job back into a v1 job
    # or drop its configured queue limits. The fenced write retains its settings.
    if mode == :durable or
         (Values.field(job, "delivery_version") != nil and Values.field(job, "manifest") != nil),
       do: Map.put(guard, "delivery", MirrorNeuron.Runtime.DeliveryChannels.settings(job)),
       else: guard
  end

  def validate_job_lease_epoch(job_id, job_map) do
    validate_persisted_lease_epoch(job_id, lease_epoch(job_map))
  end

  defp validate_persisted_lease_epoch(job_id, incoming) do
    guard = existing_job_guard(job_id)
    validate_lease_epoch_against_guard(guard, incoming)
  end

  defp validate_lease_epoch_against_guard(guard, incoming) do
    case Values.parse_integer(Map.get(guard, "cancellation_fence_epoch")) do
      fence when is_integer(fence) ->
        {:error, {:cancellation_fenced, incoming, fence}}

      nil ->
        case {incoming, lease_epoch(guard)} do
          {nil, _existing} ->
            :ok

          {_incoming, nil} ->
            :ok

          {incoming, existing} when incoming >= existing ->
            :ok

          {incoming, existing} ->
            {:error, {:stale_lease_epoch, incoming, existing}}
        end
    end
  end

  def validate_agent_lease_epoch(snapshot, job_guard_result) do
    guard =
      case job_guard_result do
        {:ok, guard} when is_map(guard) -> guard
        _ -> %{}
      end

    validate_lease_epoch_against_guard(guard, lease_epoch(snapshot))
  end

  def existing_job_guard(job_id) do
    case fetch_job_guard(job_id) do
      {:ok, guard} -> guard
      _ -> %{}
    end
  end

  def fetch_job_guard(job_id) do
    case Connection.command(["GET", Keys.key("job", job_id, "guard")]) do
      {:ok, encoded} when is_binary(encoded) ->
        Jason.decode(encoded)

      {:ok, nil} ->
        {:error, "job #{job_id} guard was not found"}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def lease_epoch(map) when is_map(map) do
    direct =
      Map.get(map, "lease_epoch") ||
        Map.get(map, :lease_epoch) ||
        Map.get(map, "cancellation_fence_epoch") ||
        Map.get(map, :cancellation_fence_epoch) ||
        get_in(map, ["lease", "epoch"]) ||
        get_in(map, [:lease, :epoch]) ||
        get_in(map, ["metadata", "lease_epoch"]) ||
        get_in(map, [:metadata, :lease_epoch])

    Values.parse_integer(direct)
  end

  def lease_epoch(_other), do: nil
end
