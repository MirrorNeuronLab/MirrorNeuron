defmodule MirrorNeuron.Runtime.StableJob.ScheduledService do
  @moduledoc "Transitions a scheduled stable service through start, resume or replacement."

  alias MirrorNeuron.Runtime.StableJob.Queries
  alias MirrorNeuron.Runtime.StableJob.Records
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.StableJob.RunCleanup
  alias MirrorNeuron.Runtime.StableJob.Runs
  alias MirrorNeuron.Runtime.StableJob.StartGate

  @terminal_statuses ["completed", "failed", "cancelled"]

  def scheduled_transition(job_id, opts \\ []) do
    StartGate.with_start_gate(job_id, fn ->
      with {:ok, definition} <- Queries.get(job_id),
           :ok <- Records.ensure_active(definition),
           :ok <- Records.ensure_owner_node(definition) do
        if RunCleanup.service_definition?(definition) do
          do_scheduled_service_transition(definition, opts)
        else
          Runs.do_start_run_result(definition, opts)
        end
      end
    end)
  end

  defp do_scheduled_service_transition(definition, opts) do
    opts = Keyword.put_new(opts, :run_id, scheduled_service_run_id(definition, opts))

    with {:ok, records} <- service_run_records(definition) do
      terminal = Enum.filter(records, &service_terminal_record?/1)
      active = Enum.reject(records, &service_terminal_record?/1)

      cond do
        Enum.any?(active, &(&1["status"] == "cancelling")) ->
          {:error, {:service_schedule_blocked, "cancellation in progress"}}

        length(active) > 1 ->
          {:error,
           {:service_schedule_blocked, "multiple active runs require an explicit replacement"}}

        true ->
          with {:ok, definition, cleanup} <-
                 RunCleanup.clear_service_runs(definition, Enum.map(terminal, & &1["run_id"])) do
            continue_scheduled_service_transition(definition, List.first(active), cleanup, opts)
          end
      end
    end
  end

  defp continue_scheduled_service_transition(definition, nil, cleanup, opts) do
    with {:ok, started} <- Runs.do_start_run_result(definition, opts) do
      action =
        if started.status == "queued",
          do: "queued",
          else: if(cleanup.replaced_run_ids == [], do: "started", else: "replaced")

      {:ok,
       started
       |> Map.put(:action, action)
       |> Map.put(:replaced_run_ids, cleanup.replaced_run_ids)
       |> Map.put(:cleanup_deferred, cleanup.cleanup_deferred)
       |> Map.put(:cleanup_pending_nodes, cleanup.cleanup_pending_nodes)}
    end
  end

  defp continue_scheduled_service_transition(
         definition,
         %{"status" => "paused"} = run,
         cleanup,
         _opts
       ) do
    case MirrorNeuron.resume(run["run_id"]) do
      {:ok, status} ->
        {:ok,
         Map.merge(cleanup, %{
           action: "resumed",
           job_id: definition["job_id"],
           run_id: run["run_id"],
           status: status,
           pid: nil
         })}

      {:error, _reason} = error ->
        error
    end
  end

  defp continue_scheduled_service_transition(
         definition,
         %{"status" => status} = run,
         cleanup,
         _opts
       )
       when status in ["queued", "pending", "validated", "scheduled", "running"] do
    {:ok,
     Map.merge(cleanup, %{
       action: if(status == "queued", do: "already_queued", else: "already_running"),
       job_id: definition["job_id"],
       run_id: run["run_id"],
       status: run["status"],
       pid: nil
     })}
  end

  defp continue_scheduled_service_transition(_definition, run, _cleanup, _opts),
    do: {:error, {:service_schedule_blocked, "run status #{run["status"]} cannot be resumed"}}

  defp service_run_records(definition) do
    definition
    |> Map.get("run_ids", [])
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, records} ->
      case RedisStore.fetch_job(run_id) do
        {:ok, run} ->
          {:cont, {:ok, [Map.put(run, "run_id", run_id) | records]}}

        {:error, reason} ->
          if RunCleanup.missing_run?(run_id, reason) do
            {:cont, {:ok, [%{"run_id" => run_id, "status" => "missing"} | records]}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
    |> then(fn
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end)
  end

  defp service_terminal_record?(%{"status" => status}),
    do: status in @terminal_statuses or status == "missing"

  defp scheduled_service_run_id(definition, opts) do
    metadata = Keyword.get(opts, :schedule_metadata, %{})

    digest =
      :crypto.hash(
        :sha256,
        Jason.encode!(%{
          job_id: definition["job_id"],
          schedule_id: metadata["schedule_id"],
          scheduled_for: metadata["scheduled_for"],
          reason: metadata["reason"],
          event_id: get_in(metadata, ["event", "event_id"])
        })
      )
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 24)

    "service_#{digest}"
  end
end
