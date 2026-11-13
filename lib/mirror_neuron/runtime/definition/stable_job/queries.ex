defmodule MirrorNeuron.Runtime.StableJob.Queries do
  @moduledoc "Definition and run discovery with compact pagination and authoritative run status."

  alias MirrorNeuron.Runtime.Page
  alias MirrorNeuron.Persistence.RedisStore

  def get(job_id), do: RedisStore.fetch_job_definition(job_id)

  def list(opts \\ []) do
    with {:ok, definitions} <- RedisStore.list_job_definitions() do
      include_archived = Keyword.get(opts, :include_archived, false)

      definitions =
        if include_archived,
          do: Enum.reject(definitions, &(&1["status"] in ["relocated", "relocation_staged"])),
          else:
            Enum.reject(
              definitions,
              &(&1["status"] in ["archived", "relocated", "relocation_staged"])
            )

      {:ok, definitions}
    end
  end

  def list_page(opts \\ []) do
    include_archived = Keyword.get(opts, :include_archived, false)

    with {:ok, definitions} <- list(include_archived: include_archived) do
      Page.paginate(
        definitions,
        opts,
        "jobs",
        %{"include_archived" => include_archived},
        &{&1["created_at"] || "", &1["job_id"] || ""}
      )
    end
  end

  def list_runs(job_id) do
    with {:ok, definition} <- get(job_id) do
      definition
      |> then(&((&1["historical_run_ids"] || []) ++ (&1["run_ids"] || [])))
      |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, runs} ->
        case RedisStore.fetch_job(run_id) do
          {:ok, run} ->
            run =
              case RedisStore.fetch_job_summary(run_id) do
                {:ok, summary} ->
                  Map.merge(run, Map.take(summary, ~w(status updated_at running_time)))

                _ ->
                  run
              end

            {:cont, {:ok, [normalize_run(run, job_id, run_id) | runs]}}

          {:error, _missing} ->
            {:cont, {:ok, runs}}
        end
      end)
      |> then(fn {:ok, runs} -> {:ok, Enum.reverse(runs)} end)
    end
  end

  def list_runs_page(job_id, opts \\ []) do
    with {:ok, runs} <- list_runs(job_id) do
      Page.paginate(
        runs,
        opts,
        "job-runs:#{job_id}",
        %{"job_id" => job_id},
        &{&1["submitted_at"] || &1["started_at"] || "", &1["run_id"] || ""}
      )
    end
  end

  defp normalize_run(run, job_id, run_id) do
    run
    |> Map.put("job_id", job_id)
    |> Map.put("run_id", run_id)
    |> Map.put_new("attempt_id", "#{run_id}:#{Map.get(run, "attempt", 1)}")
  end
end
