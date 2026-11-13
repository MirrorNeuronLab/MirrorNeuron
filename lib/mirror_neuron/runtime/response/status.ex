defmodule MirrorNeuron.Runtime.JobResponse.Status do
  @moduledoc "Public response service state and safe lifecycle diagnostics."

  require Logger

  alias MirrorNeuron.Runtime.JobResponse.Lifecycle
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.SafeAccess

  @states ~w(disabled starting ready degraded failed stopped)

  def status(definition) when is_map(definition) do
    cond do
      not Lifecycle.enabled?(definition) ->
        %{"state" => "disabled"}

      definition["status"] != "active" ->
        %{
          "state" => "stopped",
          "stopped_at" => definition["updated_at"] || definition["created_at"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      Lifecycle.local_owner?(definition) ->
        status_local(definition["job_id"])
        |> maybe_put_started(definition)

      true ->
        remote_status(definition)
        |> maybe_put_started(definition)
    end
  end

  def status_local(job_id) when is_binary(job_id) do
    case Lifecycle.lookup(job_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, :status, 1_000)
        catch
          :exit, _ -> %{"state" => "starting"}
        end

      :error ->
        %{"state" => "starting"}
    end
  end

  defp remote_status(definition) do
    with {:ok, owner} <- SafeAccess.node_name_to_atom(definition["owner_node"]),
         result when is_map(result) <-
           NodeAdapter.rpc_call(
             owner,
             MirrorNeuron.Runtime.JobResponse,
             :status_local,
             [definition["job_id"]],
             1_000
           ) do
      result
    else
      _ -> %{"state" => "starting"}
    end
  end

  def public_state(state) do
    %{
      "state" => normalize_state(state.state, "failed"),
      "started_at" => state.started_at,
      "ready_at" => state.ready_at,
      "updated_at" => state.updated_at,
      "stopped_at" => state.stopped_at,
      "safe_error_code" => state.safe_error_code
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def normalize_state(value, _fallback) when value in @states, do: value

  def normalize_state(_value, fallback), do: fallback

  def safe_error_code(reason) do
    text = String.downcase(inspect(reason))

    cond do
      String.contains?(text, "unavailable") ->
        "native_unavailable"

      String.contains?(text, ["saturat", "mn_overload", "resource_exhausted"]) ->
        "saturated"

      String.contains?(text, "deadline") or String.contains?(text, "timeout") ->
        "deadline_exceeded"

      String.contains?(text, "conflict") ->
        "request_conflict"

      true ->
        "response_failed"
    end
  end

  defp maybe_put_started(value, definition) do
    case definition["updated_at"] || definition["created_at"] do
      timestamp when is_binary(timestamp) and timestamp != "" ->
        Map.put_new(value, "started_at", timestamp)

      _missing ->
        value
    end
  end

  def log_event(job_id, operation, state, latency_ms, error_code \\ nil) do
    Logger.info(
      "job response lifecycle",
      job_id: job_id,
      operation: operation,
      state: state,
      latency_ms: latency_ms,
      error_code: error_code
    )
  end
end
