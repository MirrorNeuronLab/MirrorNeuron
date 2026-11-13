defmodule MirrorNeuron.Monitor.Agents do
  @moduledoc "Projects worker, sandbox and heartbeat observations."

  @default_live_window_ms 300_000

  def summarize_agent(agent) do
    agent_type = Map.get(agent, "agent_type")
    lease = Map.get(agent, "lease") || %{}
    sandbox = Map.get(agent, "sandbox") || %{}
    last_error = Map.get(agent, "last_error")
    processed_messages = Map.get(agent, "processed_messages", 0)
    mailbox_depth = Map.get(agent, "mailbox_depth", 0)
    paused? = get_in(agent, ["metadata", "paused"]) || false
    sandbox_name = Map.get(sandbox, "name")
    sandbox_status = Map.get(sandbox, "status")

    %{
      "agent_id" => Map.get(agent, "agent_id"),
      "agent_type" => agent_type,
      "assigned_node" => Map.get(agent, "assigned_node"),
      "processed_messages" => processed_messages,
      "mailbox_depth" => mailbox_depth,
      "paused?" => paused?,
      "last_heartbeat_at" => Map.get(agent, "last_heartbeat_at"),
      "live?" => agent_live?(agent),
      "status" => agent_status(agent_type, paused?, sandbox_status, last_error, mailbox_depth),
      "running?" => running_agent?(agent_type, sandbox_status, last_error),
      "last_error" => last_error,
      "backpressure" => get_in(agent, ["metadata", "backpressure"]) || %{},
      "sandbox_name" => sandbox_name,
      "lease" => %{
        "lease_id" => Map.get(lease, "lease_id"),
        "pool" => Map.get(lease, "pool"),
        "slots" => Map.get(lease, "slots")
      }
    }
  end

  def sandbox_summaries(events, agents) do
    sandboxes_from_events =
      events
      |> Enum.filter(&(&1["type"] in ["sandbox_job_completed", "sandbox_job_failed"]))
      |> Enum.map(fn event ->
        payload = Map.get(event, "payload", %{})

        %{
          "agent_id" => Map.get(event, "agent_id"),
          "sandbox_name" => Map.get(payload, "sandbox_name"),
          "exit_code" => Map.get(payload, "exit_code"),
          "pool" => Map.get(payload, "pool"),
          "timestamp" => Map.get(event, "timestamp")
        }
      end)

    sandboxes_from_agents =
      agents
      |> Enum.map(fn agent ->
        %{
          "agent_id" => agent["agent_id"],
          "sandbox_name" => agent["sandbox_name"],
          "exit_code" => nil,
          "pool" => get_in(agent, ["lease", "pool"]),
          "timestamp" => nil
        }
      end)

    (sandboxes_from_events ++ sandboxes_from_agents)
    |> Enum.reject(&is_nil(&1["sandbox_name"]))
    |> Enum.uniq_by(&{&1["agent_id"], &1["sandbox_name"]})
    |> Enum.sort_by(&{&1["agent_id"], &1["sandbox_name"]})
  end

  defp running_agent?("executor", status, nil),
    do: status in [nil, "pending", "starting", "running"]

  defp running_agent?(_agent_type, _sandbox_status, _last_error), do: false

  defp agent_status(_agent_type, true, _sandbox_status, _last_error, _mailbox_depth), do: "paused"

  defp agent_status("executor", false, _sandbox_status, last_error, _mailbox_depth)
       when is_binary(last_error) and last_error != "",
       do: "error"

  defp agent_status("executor", false, sandbox_status, _last_error, mailbox_depth) do
    cond do
      mailbox_depth > 0 -> "queued"
      sandbox_status in ["completed", "failed", "cancelled"] -> sandbox_status
      true -> "running"
    end
  end

  defp agent_status(_agent_type, false, _sandbox_status, _last_error, mailbox_depth) do
    if mailbox_depth > 0, do: "busy", else: "ready"
  end

  defp agent_live?(agent) do
    heartbeat = Map.get(agent, "last_heartbeat_at")
    interval_ms = get_in(agent, ["metadata", "heartbeat_interval_ms"]) || 2_000
    live_window_ms = max(interval_ms * 3, @default_live_window_ms)
    recent_timestamp?(heartbeat, live_window_ms)
  end

  def recent_timestamp?(nil, _window_ms), do: false

  def recent_timestamp?(timestamp, window_ms) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(timestamp) do
      abs(DateTime.diff(DateTime.utc_now(), dt, :millisecond)) <= window_ms
    else
      _ -> false
    end
  end
end
