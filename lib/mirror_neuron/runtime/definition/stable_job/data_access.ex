defmodule MirrorNeuron.Runtime.StableJob.DataAccess do
  @moduledoc "Checks active run conflicts against the definition-owned read/write data contract."

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob.Storage

  @terminal_statuses ["completed", "failed", "cancelled"]

  def ensure_no_active_runs(definition) do
    with {:ok, active} <- active_run_records(definition) do
      run_ids = Enum.map(active, & &1["run_id"])
      if run_ids == [], do: :ok, else: {:error, {:active_runs, run_ids}}
    end
  end

  def ensure_job_data_access(definition, requested_access) do
    with {:ok, active} <- active_run_records(definition) do
      conflicting =
        Enum.filter(active, fn run ->
          requested_access == "read_write" or run_job_data_access(run) == "read_write"
        end)

      if conflicting == [] do
        :ok
      else
        {:error, {:job_data_busy, Enum.map(conflicting, & &1["run_id"])}}
      end
    end
  end

  defp active_run_records(definition) do
    definition
    |> Map.get("run_ids", [])
    |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, active} ->
      case RedisStore.execution_exists?(run_id) do
        {:ok, false} ->
          {:cont, {:ok, active}}

        {:ok, true} ->
          case RedisStore.fetch_job(run_id) do
            {:ok, %{"status" => status}} when status in @terminal_statuses ->
              {:cont, {:ok, active}}

            {:ok, run} ->
              {:cont, {:ok, [Map.put(run, "run_id", run_id) | active]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def requested_job_data_access(definition, opts) do
    Keyword.get(opts, :job_data_access, Storage.default_job_data_access(definition["storage"]))
    |> normalize_job_data_access()
  end

  defp run_job_data_access(run) do
    run["job_data_access"] ||
      get_in(run, ["manifest", "metadata", "job_data_access"])
      |> normalize_job_data_access()
  end

  def normalize_job_data_access(access) when access in ["read", "read_only", "ro"], do: "read"

  def normalize_job_data_access(_access), do: "read_write"
end
