defmodule MirrorNeuron.Runtime.StableJob.RunCleanup do
  @moduledoc "Retires old service runs and historical runs before detaching their durable references."

  alias MirrorNeuron.Runtime.StableJob.DataAccess
  alias MirrorNeuron.Runtime.StableJob.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime

  @terminal_statuses ["completed", "failed", "cancelled"]

  def empty_replacement do
    %{
      replaced_run_ids: [],
      cleanup_deferred: false,
      cleanup_pending_nodes: []
    }
  end

  def prepare_bundle_replacement(definition, bundle, opts) do
    replace_existing = Keyword.get(opts, :replace_existing_run, false)
    target_service = bundle.manifest.type == "service"
    run_ids = definition |> Map.get("run_ids", []) |> Enum.uniq()

    cond do
      replace_existing and not target_service ->
        {:error, :replacement_requires_service_job}

      replace_existing ->
        clear_service_runs(definition)

      target_service and length(run_ids) > 1 ->
        {:error, {:service_run_exists, run_ids}}

      true ->
        with :ok <- DataAccess.ensure_no_active_runs(definition) do
          {:ok, definition, empty_replacement()}
        end
    end
  end

  def clear_service_runs(definition, run_ids \\ nil) do
    selected = Enum.uniq(run_ids || Map.get(definition, "run_ids", []))

    if selected == [] do
      {:ok, definition, empty_replacement()}
    else
      with {:ok, cleanup} <- cleanup_service_run_ids(selected),
           remaining <- Enum.reject(Map.get(definition, "run_ids", []), &(&1 in selected)),
           updated <-
             definition
             |> Map.put("run_ids", remaining)
             |> Map.put("latest_run_id", List.last(remaining))
             |> Map.put("updated_at", Runtime.timestamp())
             |> Records.increment_revision(),
           {:ok, saved} <- RedisStore.persist_job_definition(definition["job_id"], updated) do
        {:ok, saved,
         %{
           replaced_run_ids: selected,
           cleanup_deferred: cleanup.pending_nodes != [],
           cleanup_pending_nodes: cleanup.pending_nodes
         }}
      end
    end
  end

  defp cleanup_service_run_ids(run_ids) do
    Enum.reduce_while(run_ids, {:ok, %{pending_nodes: []}}, fn run_id, {:ok, cleanup} ->
      case cleanup_run(run_id) do
        {:ok, result} ->
          pending_nodes =
            cleanup.pending_nodes
            |> Kernel.++(Map.get(result, "cleanup_pending_nodes", []))
            |> Kernel.++(Map.get(result, :cleanup_pending_nodes, []))
            |> Enum.uniq()

          {:cont, {:ok, %{pending_nodes: pending_nodes}}}

        {:error, reason} ->
          {:halt, {:error, {:service_run_cleanup_failed, run_id, reason}}}
      end
    end)
  end

  def cleanup_run(run_id) do
    case RedisStore.fetch_job(run_id) do
      {:ok, %{"status" => status}} when status in @terminal_statuses ->
        Runtime.clear_job_with_result(run_id)

      {:ok, _active} ->
        with {:ok, _status} <- MirrorNeuron.cancel(run_id),
             {:ok, result} <- Runtime.clear_job_with_result(run_id) do
          {:ok, result}
        end

      {:error, reason} ->
        if missing_run?(run_id, reason) do
          with :ok <- Runtime.cleanup_job_resources(run_id, nil),
               :ok <- RedisStore.delete_job(run_id) do
            {:ok, %{}}
          end
        else
          {:error, reason}
        end
    end
  end

  def service_definition?(definition) do
    definition["type"] == "service"
  end

  def delete_historical_runs(definition) do
    definition
    |> then(&((&1["historical_run_ids"] || []) ++ (&1["run_ids"] || [])))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn run_id, :ok ->
      case delete_historical_run(run_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:run_cleanup_failed, run_id, reason}}}
      end
    end)
  end

  defp delete_historical_run(run_id) do
    case cleanup_run(run_id) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def missing_run?(run_id, reason),
    do: reason == "job #{run_id} was not found"
end
