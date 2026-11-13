defmodule MirrorNeuron.Cluster.NodeDrainer.State do
  @moduledoc "Persists node drain transitions and publishes lifecycle events."

  require Logger

  alias MirrorNeuron.Cluster.NodeDrainer.Results
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Cluster.NodeDrainer.Settings

  def mark_draining(context) do
    drain = %{
      "status" => "draining",
      "started_at" => context.started_at,
      "deadline_at" => context.deadline_at,
      "deadline_ms" => context.deadline_ms,
      "reason" => context.reason,
      "ignore_system_jobs" => context.ignore_system_jobs,
      "completed_at" => nil,
      "counters" => %{}
    }

    put_node_state(context.node, "draining", context.opts, %{
      "scheduling_eligible" => false,
      "drain" => drain
    })
  end

  def maybe_complete_drain(result, context) do
    result =
      result
      |> put_in(["counters"], Results.counters(result["actions"]))
      |> Map.put("deadline_at", context.deadline_at)
      |> Map.put("started_at", context.started_at)
      |> Map.put("reason", context.reason)

    status = Results.drain_status(result)

    if context.dry_run? do
      Map.merge(result, %{"status" => "dry_run", "would_status" => status})
    else
      drain = %{
        "status" => status,
        "started_at" => context.started_at,
        "deadline_at" => context.deadline_at,
        "deadline_ms" => context.deadline_ms,
        "reason" => context.reason,
        "ignore_system_jobs" => context.ignore_system_jobs,
        "completed_at" => if(status == "complete", do: Runtime.timestamp(), else: nil),
        "counters" => result["counters"]
      }

      node_status = if status == "complete", do: "maintenance", else: "draining"

      {:ok, _state} =
        put_node_state(context.node, node_status, context.opts, %{
          "scheduling_eligible" => false,
          "drain" => drain
        })

      publish_drain_progress(status, context, result)

      result
      |> Map.put("status", status)
      |> Map.put("node_status", node_status)
      |> Map.put("scheduling_eligible", false)
    end
  end

  defp publish_drain_progress("complete", context, result),
    do: publish_node_event(:node_drain_completed, context, %{"result" => result})

  defp publish_drain_progress("blocked_no_placement", context, result),
    do: publish_node_event(:node_drain_blocked, context, %{"result" => result})

  defp publish_drain_progress(_status, context, result),
    do: publish_node_event(:node_drain_progress, context, %{"result" => result})

  def node_state(node, opts) do
    node_state = Settings.node_state_module(opts)

    cond do
      function_exported?(node_state, :fetch, 1) ->
        case node_state.fetch(node) do
          {:ok, state} when is_map(state) -> state
          _ -> %{"node" => node}
        end

      true ->
        %{"node" => node}
    end
  rescue
    _ -> %{"node" => node}
  end

  def put_node_state(node, status, opts, updates) do
    node_state = Settings.node_state_module(opts)
    existing = node_state(node, opts)
    attrs = existing |> Map.merge(updates) |> Map.put("node", node)

    if function_exported?(node_state, :mark, 3) do
      node_state.mark(node, status, attrs)
    else
      {:ok, Map.put(attrs, "status", status)}
    end
  end

  def publish_node_event(type, context, extra) do
    event =
      %{
        type: type,
        node: context.node,
        reason: context.reason,
        timestamp: Runtime.timestamp()
      }
      |> Map.merge(extra)

    Settings.event_bus(context.opts).publish("__cluster__", event)
  rescue
    reason ->
      Logger.debug("failed to publish node drain event #{inspect(type)}: #{inspect(reason)}")
      :ok
  catch
    _kind, reason ->
      Logger.debug("failed to publish node drain event #{inspect(type)}: #{inspect(reason)}")
      :ok
  end
end
