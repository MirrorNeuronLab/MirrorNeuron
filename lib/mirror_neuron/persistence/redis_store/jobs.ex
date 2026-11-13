defmodule MirrorNeuron.Persistence.RedisStore.Jobs do
  @moduledoc "Durable run snapshots, compact projections and atomic terminal transitions."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Guards
  alias MirrorNeuron.Persistence.RedisStore.JobRetention
  alias MirrorNeuron.Persistence.JobSummary
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.RetentionPolicy
  alias MirrorNeuron.Persistence.RedisStore.Values

  @jobs_set "jobs"

  defp with_run_clock(job_id, job_map) do
    case Connection.command(["GET", Keys.key("job", job_id, "summary")]) do
      {:ok, encoded} ->
        with {:ok, previous} when is_map(previous) <- Jason.decode(encoded || "{}") do
          clock = MirrorNeuron.Runtime.RunClock.advance(previous, job_map)
          {:ok, Map.put(job_map, "running_time", clock)}
        else
          _ -> {:error, "invalid persisted running-time record"}
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def persist_job(job_id, job_map) when is_map(job_map) do
    with :ok <- Values.validate_identifier("job_id", job_id),
         {:ok, job_map} <- with_run_clock(job_id, job_map) do
      encoded = Jason.encode!(Map.delete(job_map, :terminal_event))
      encoded_summary = Jason.encode!(job_summary(job_id, job_map))
      encoded_guard = Jason.encode!(Guards.job_guard(job_id, job_map))

      with :ok <- Guards.validate_job_lease_epoch(job_id, job_map),
           {:ok, results} <-
             persist_fenced_job(job_id, encoded, encoded_summary, encoded_guard, job_map),
           :ok <- Results.expect_persist_job_results(results),
           :ok <- JobRetention.apply_job_retention(job_id, job_map),
           :ok <- Connection.wait_for_replicas() do
        {:ok, job_map}
      end
    end
  end

  def persist_job(_job_id, _job_map), do: {:error, "job must be an object"}

  @doc false
  def persist_terminal_transition(job_id, job_map, event) do
    event_id = Map.get(event, :event_id) || Map.fetch!(event, "event_id")
    job_map = job_map |> Map.delete("pending_finalization") |> Map.delete(:pending_finalization)
    job_map = job_map |> Map.put(:finalization_id, event_id) |> Map.put(:terminal_event, event)
    persist_job(job_id, job_map)
  end

  # Check the guard and publish the new record in one Redis operation. A
  # previous attempt cannot pass a check and then overwrite a newer epoch.

  defp persist_fenced_job(job_id, encoded, summary, guard, job_map) do
    epoch = Guards.lease_epoch(job_map)
    event = Map.get(job_map, :terminal_event)
    event = if event, do: Jason.encode!(event), else: ""
    event_id = Values.field(job_map, "finalization_id", "")

    case MirrorNeuron.Persistence.FencedJobStore.write(
           &Connection.command/1,
           [
             Keys.key("job", job_id),
             Keys.key("job", job_id, "summary"),
             Keys.key("job", job_id, "guard"),
             Keys.key(@jobs_set),
             Keys.key("job", job_id, "events")
           ],
           [
             encoded,
             summary,
             guard,
             job_id,
             to_string(epoch || -1),
             event,
             event_id,
             to_string(RetentionPolicy.event_max_count()),
             to_string(RetentionPolicy.event_ttl_seconds()),
             Keys.channel("events", job_id)
           ]
         ) do
      {:ok, -1} ->
        {:error, {:stale_lease_epoch, epoch, Guards.existing_job_guard(job_id)["lease_epoch"]}}

      {:ok, -2} ->
        {:error,
         {:cancellation_fenced, epoch,
          Guards.existing_job_guard(job_id)["cancellation_fence_epoch"]}}

      {:ok, -3} ->
        {:error, :conflicting_finalization}

      {:ok, result} ->
        {:ok, ["OK", "OK", "OK", result]}

      error ->
        error
    end
  end

  @doc false
  def persist_job_projection(job_id, job_map) when is_map(job_map) do
    with :ok <- Values.validate_identifier("job_id", job_id),
         {:ok, job_map} <- with_run_clock(job_id, job_map) do
      encoded_summary = Jason.encode!(job_summary(job_id, job_map))
      encoded_guard = Jason.encode!(Guards.job_guard(job_id, job_map, :projection))

      with :ok <- Guards.validate_job_lease_epoch(job_id, job_map),
           {:ok, results} <-
             persist_fenced_job_projection(job_id, encoded_summary, encoded_guard, job_map),
           :ok <- Results.expect_persist_job_projection_results(results),
           :ok <- JobRetention.apply_job_projection_retention(job_id, job_map),
           :ok <- Connection.wait_for_replicas() do
        {:ok, job_map}
      end
    end
  end

  def persist_job_projection(_job_id, _job_map),
    do: {:error, "job must be an object"}

  defp persist_fenced_job_projection(job_id, summary, guard, job_map) do
    case persist_fenced_job(job_id, "", summary, guard, job_map) do
      {:ok, [_root, a, b, c]} -> {:ok, [a, b, c]}
      error -> error
    end
  end

  def persist_terminal_job(job_id, updates, defaults \\ %{})

  def persist_terminal_job(job_id, updates, defaults) when is_map(updates) and is_map(defaults) do
    with :ok <- Values.validate_identifier("job_id", job_id) do
      existing =
        case fetch_job(job_id) do
          {:ok, job} when is_map(job) -> job
          _ -> %{}
        end

      job_map =
        defaults
        |> Map.merge(existing)
        |> Map.merge(updates)
        |> Map.delete("clock_session")
        |> Map.put("job_id", job_id)
        |> Map.put_new("submitted_at", Values.timestamp())
        |> Map.put("updated_at", Values.timestamp())

      persist_job(job_id, job_map)
    end
  end

  def persist_terminal_job(_job_id, _updates, _defaults),
    do: {:error, "job updates and defaults must be objects"}

  def fetch_job(job_id) do
    with :ok <- Values.validate_identifier("job_id", job_id) do
      case Connection.command(["GET", Keys.key("job", job_id)]) do
        {:ok, nil} -> {:error, "job #{job_id} was not found"}
        {:ok, contents} -> Jason.decode(contents)
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  def fetch_delivery_settings(job_id) do
    with :ok <- Values.validate_identifier("job_id", job_id) do
      case Guards.fetch_job_guard(job_id) do
        {:ok, %{"delivery" => settings}} ->
          {:ok, settings}

        {:ok, _} ->
          {:error, :unsupported_delivery_settings}

        error ->
          error
      end
    end
  end

  def fetch_job_summary(job_id) do
    with :ok <- Values.validate_identifier("job_id", job_id) do
      case Connection.command(["GET", Keys.key("job", job_id, "summary")]) do
        {:ok, nil} -> {:error, "job #{job_id} summary was not found"}
        {:ok, contents} -> Jason.decode(contents)
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  def list_job_ids do
    case Connection.command(["SMEMBERS", Keys.key(@jobs_set)]) do
      {:ok, job_ids} -> {:ok, Enum.sort(job_ids)}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def list_jobs do
    with {:ok, job_ids} <- list_job_ids() do
      fetch_jobs(job_ids)
    end
  end

  def list_job_summaries do
    with {:ok, job_ids} <- list_job_ids() do
      fetch_job_summaries(job_ids)
    end
  end

  def execution_exists?(run_id) do
    with :ok <- Values.validate_identifier("run_id", run_id) do
      case Connection.command(["EXISTS", Keys.key("job", run_id)]) do
        {:ok, 0} -> {:ok, false}
        {:ok, "0"} -> {:ok, false}
        {:ok, _count} -> {:ok, true}
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  defp fetch_jobs([]), do: {:ok, []}

  defp fetch_jobs(job_ids) do
    keys = Enum.map(job_ids, &Keys.key("job", &1))

    case Connection.command(["MGET" | keys]) do
      {:ok, encoded_jobs} -> {:ok, Values.decode_json_items(encoded_jobs)}
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  defp fetch_job_summaries([]), do: {:ok, []}

  defp fetch_job_summaries(job_ids) do
    keys = Enum.map(job_ids, &Keys.key("job", &1, "summary"))

    case Connection.command(["MGET" | keys]) do
      {:ok, encoded_summaries} ->
        summaries =
          job_ids
          |> Enum.zip(encoded_summaries)
          |> Enum.map(fn
            {_job_id, encoded} when is_binary(encoded) ->
              case Jason.decode(encoded) do
                {:ok, summary} when is_map(summary) -> summary
                _ -> nil
              end

            {_job_id, _missing} ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, summaries}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  defp job_summary(job_id, job), do: JobSummary.build(job_id, job)

  def missing_job?(job_id, reason), do: reason == "job #{job_id} was not found"
end
