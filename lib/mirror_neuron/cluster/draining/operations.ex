defmodule MirrorNeuron.Cluster.NodeDrainer.Operations do
  @moduledoc "Runs node drains, cancellation, maintenance and pending drain sweeps."

  alias MirrorNeuron.Cluster.NodeDrainer.Jobs
  alias MirrorNeuron.Cluster.NodeDrainer.Results
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Cluster.NodeDrainer.Settings
  alias MirrorNeuron.Cluster.NodeDrainer.State

  @default_deadline_ms 1_800_000

  def drain_node(node, opts \\ []) do
    node_name = Settings.node_name(node)
    dry_run? = Settings.option(opts, :dry_run, false)
    continue? = Settings.option(opts, :continue, false)
    existing = State.node_state(node_name, opts)
    existing_drain = Map.get(existing, "drain", %{})
    now = Runtime.timestamp()

    context = %{
      node: node_name,
      dry_run?: dry_run?,
      continue?: continue?,
      reason:
        Settings.option(opts, :reason) ||
          Map.get(existing_drain, "reason") ||
          "operator requested node drain",
      ignore_system_jobs:
        Settings.option(
          opts,
          :ignore_system_jobs,
          Map.get(existing_drain, "ignore_system_jobs", true)
        ) != false,
      deadline_ms: Settings.option(opts, :deadline_ms, @default_deadline_ms),
      started_at: if(continue?, do: Map.get(existing_drain, "started_at") || now, else: now),
      deadline_at:
        if continue? and Map.get(existing_drain, "deadline_at") do
          Map.get(existing_drain, "deadline_at")
        else
          Settings.iso_after(Settings.option(opts, :deadline_ms, @default_deadline_ms))
        end,
      opts: opts
    }

    unless dry_run? do
      {:ok, _state} = State.mark_draining(context)
      State.publish_node_event(:node_drain_started, context, %{})
    end

    with {:ok, jobs} <- Settings.list_jobs(opts) do
      result =
        jobs
        |> Enum.filter(&Jobs.active_job?/1)
        |> Enum.filter(&Jobs.job_on_node?(&1, node_name))
        |> Jobs.filter_only_job_ids(Settings.option(opts, :only_job_ids))
        |> Enum.reduce(Results.empty_result(context), fn job, acc ->
          Results.record_action(acc, Jobs.process_job(job, context))
        end)
        |> State.maybe_complete_drain(context)

      {:ok, result}
    end
  end

  def drain_job(job_id, node, opts \\ []) when is_binary(job_id) do
    with {:ok, result} <-
           drain_node(node, Keyword.put(opts, :only_job_ids, [job_id])) do
      action =
        result
        |> Map.get("actions", [])
        |> List.first()
        |> Kernel.||(%{
          "job_id" => job_id,
          "status" => "skipped",
          "reason" => "job was not selected"
        })

      {:ok, action}
    end
  end

  def cancel_node_drain(node, opts \\ []) do
    node_name = Settings.node_name(node)
    reason = Settings.option(opts, :reason, "operator cancelled node drain")
    mark_eligible? = Settings.option(opts, :mark_eligible, false)
    now = Runtime.timestamp()
    existing = State.node_state(node_name, opts)

    status = if mark_eligible?, do: "healthy", else: "maintenance"

    drain =
      existing
      |> Map.get("drain", %{})
      |> Map.merge(%{
        "status" => "cancelled",
        "reason" => reason,
        "completed_at" => now,
        "cancelled_at" => now
      })

    {:ok, state} =
      State.put_node_state(node_name, status, opts, %{
        "scheduling_eligible" => mark_eligible?,
        "drain" => drain
      })

    result = %{
      "node" => node_name,
      "status" => "cancelled",
      "scheduling_eligible" => mark_eligible?,
      "reason" => reason,
      "node_state" => state
    }

    State.publish_node_event(
      :node_drain_cancelled,
      %{node: node_name, reason: reason, opts: opts},
      %{
        mark_eligible: mark_eligible?
      }
    )

    {:ok, result}
  end

  def set_node_maintenance(node, enabled, opts \\ []) do
    node_name = Settings.node_name(node)
    enabled? = enabled in [true, "true", "TRUE", "1", 1, "yes", "on"]
    reason = Settings.option(opts, :reason, "operator changed node maintenance")
    now = Runtime.timestamp()
    existing = State.node_state(node_name, opts)

    {status, eligible, event_type} =
      if enabled? do
        {"maintenance", false, :node_maintenance_enabled}
      else
        {"healthy", true, :node_maintenance_disabled}
      end

    maintenance =
      %{
        "enabled" => enabled?,
        "reason" => reason,
        "updated_at" => now
      }
      |> Settings.maybe_put("disabled_at", if(enabled?, do: nil, else: now))

    {:ok, state} =
      State.put_node_state(node_name, status, opts, %{
        "scheduling_eligible" => eligible,
        "maintenance" => maintenance,
        "drain" => Map.get(existing, "drain")
      })

    result = %{
      "node" => node_name,
      "status" => status,
      "scheduling_eligible" => eligible,
      "maintenance" => maintenance,
      "node_state" => state
    }

    State.publish_node_event(event_type, %{node: node_name, reason: reason, opts: opts}, %{})
    {:ok, result}
  end

  def node_drain_status(node, opts \\ []) do
    node_name = Settings.node_name(node)
    state = State.node_state(node_name, opts)

    {:ok,
     %{
       "node" => node_name,
       "status" => Map.get(state, "status", "unknown"),
       "scheduling_eligible" => Map.get(state, "scheduling_eligible", true),
       "drain" => Map.get(state, "drain", %{}),
       "maintenance" => Map.get(state, "maintenance", %{}),
       "node_state" => state
     }}
  end

  def process_due_drains(opts \\ []) do
    with {:ok, states} <- Settings.list_node_states(opts) do
      states
      |> Enum.filter(&Settings.due_drain_state?/1)
      |> Enum.reduce({:ok, Results.empty_sweep_result()}, fn state, {:ok, acc} ->
        node = Map.get(state, "node")

        case drain_node(node, Keyword.merge(opts, continue: true)) do
          {:ok, result} -> {:ok, Results.merge_sweep_result(acc, result)}
          {:error, reason} -> {:ok, Results.record_sweep_failure(acc, node, reason)}
        end
      end)
    end
  end
end
