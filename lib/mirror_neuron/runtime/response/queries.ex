defmodule MirrorNeuron.Runtime.JobResponse.Queries do
  @moduledoc "Validates local or forwarded queries and preserves one durable request identity."

  alias MirrorNeuron.Runtime.JobResponse.Fallback
  alias MirrorNeuron.Runtime.JobResponse.Lifecycle
  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.SafeAccess
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.Runtime.JobResponse.Status
  alias MirrorNeuron.Runtime.JobResponse.Validation

  @query_timeout 50_000
  @rpc_timeout 55_000

  def query(job_id, attrs) when is_binary(job_id) and is_map(attrs) do
    with :ok <- Validation.validate_query(attrs),
         {:ok, definition} <- StableJob.get(job_id),
         :ok <- Validation.ensure_queryable(definition) do
      if Lifecycle.local_owner?(definition) do
        query_local(job_id, attrs)
      else
        query_remote(definition, attrs)
      end
    end
  end

  def query_local(job_id, attrs) when is_binary(job_id) and is_map(attrs) do
    with :ok <- Validation.validate_query(attrs),
         {:ok, definition} <- StableJob.get(job_id),
         :ok <- Validation.ensure_queryable(definition),
         :ok <- normalize_start_result(Lifecycle.ensure_started(definition)) do
      case Lifecycle.lookup(job_id) do
        {:ok, pid} ->
          perform_query(pid, definition, attrs)

        :error ->
          {:ok, Fallback.fallback(attrs, definition, "failed", "response_service_unavailable")}
      end
    end
  end

  def get_turn(job_id, turn_id) when is_binary(job_id) and is_binary(turn_id) do
    with :ok <- Validation.validate_turn_id(turn_id),
         {:ok, definition} <- StableJob.get(job_id),
         :ok <- Validation.ensure_queryable(definition),
         :ok <- Validation.ensure_agent_enabled(definition) do
      if Lifecycle.local_owner?(definition) do
        get_turn_local(job_id, turn_id)
      else
        get_turn_remote(definition, turn_id)
      end
    end
  end

  def get_turn(_job_id, _turn_id), do: {:error, :invalid_turn_id}

  def get_turn_local(job_id, turn_id) do
    with :ok <- Validation.validate_turn_id(turn_id),
         {:ok, definition} <- StableJob.get(job_id),
         :ok <- Validation.ensure_queryable(definition),
         :ok <- Validation.ensure_agent_enabled(definition),
         :ok <- normalize_start_result(Lifecycle.ensure_started(definition)) do
      ModelServices.job_response_command(
        %{
          "kind" => "job_response",
          "operation" => "turn",
          "job_id" => job_id,
          "turn_id" => turn_id
        },
        10_000
      )
    end
  end

  defp perform_query(pid, definition, attrs) do
    attrs =
      if attrs["request_id"] in [nil, ""],
        do:
          Map.put(
            attrs,
            "request_id",
            Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
          ),
        else: attrs

    started = System.monotonic_time(:millisecond)

    result =
      MirrorNeuron.Runtime.DurableReply.query(
        %{
          "kind" => "job_response",
          "operation" => "query",
          "job_id" => definition["job_id"],
          "question" => attrs["question"],
          "conversation_id" => attrs["conversation_id"],
          "request_id" => attrs["request_id"],
          "context" => attrs["context"] || %{}
        },
        @query_timeout
      )

    latency = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, answer} ->
        service_state = Status.normalize_state(get_in(answer, ["service", "state"]), "ready")
        Status.log_event(definition["job_id"], "query", service_state, latency)
        GenServer.cast(pid, {:query_result, service_state, nil})
        {:ok, answer}

      {:error, reason} ->
        code = Status.safe_error_code(reason)

        cond do
          code == "saturated" ->
            {:error,
             {:retry_later,
              %{
                "accepted" => false,
                "scope" => "responses",
                "request_id" => attrs["request_id"],
                "retry_after_ms" => 250
              }}}

          code == "request_conflict" ->
            Status.log_event(definition["job_id"], "failure", "ready", latency, code)
            {:error, :request_conflict}

          true ->
            Status.log_event(definition["job_id"], "fallback", "degraded", latency, code)
            GenServer.cast(pid, {:query_result, "degraded", code})
            {:ok, Fallback.fallback(attrs, definition, "degraded", code)}
        end
    end
  end

  defp get_turn_remote(definition, turn_id) do
    with {:ok, owner} <- SafeAccess.node_name_to_atom(definition["owner_node"]) do
      case NodeAdapter.rpc_call(
             owner,
             MirrorNeuron.Runtime.JobResponse,
             :get_turn_local,
             [definition["job_id"], turn_id],
             @rpc_timeout
           ) do
        {:badrpc, _reason} -> {:error, :owner_node_unavailable}
        result -> result
      end
    else
      _ -> {:error, :owner_node_unavailable}
    end
  end

  defp query_remote(definition, attrs) do
    with {:ok, owner} <- SafeAccess.node_name_to_atom(definition["owner_node"]) do
      case NodeAdapter.rpc_call(
             owner,
             MirrorNeuron.Runtime.JobResponse,
             :query_local,
             [definition["job_id"], attrs],
             @rpc_timeout
           ) do
        {:badrpc, _reason} ->
          {:ok, Fallback.fallback(attrs, definition, "failed", "owner_node_unavailable")}

        result ->
          result
      end
    else
      _ -> {:ok, Fallback.fallback(attrs, definition, "failed", "owner_node_unavailable")}
    end
  end

  defp normalize_start_result(:ok), do: :ok

  defp normalize_start_result({:error, reason}), do: {:error, reason}
end
