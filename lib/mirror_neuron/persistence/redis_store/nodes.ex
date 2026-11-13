defmodule MirrorNeuron.Persistence.RedisStore.Nodes do
  @moduledoc "Node state records and corruption-aware membership listing."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Values

  def persist_node_state(node_name, attrs) do
    state =
      attrs
      |> Values.stringify_map()
      |> Map.put("node", node_name)
      |> Map.put("updated_at", Values.timestamp())

    with {:ok, results} <-
           Connection.transaction([
             ["SET", Keys.key("node", node_name, "state"), Jason.encode!(state)],
             ["SADD", Keys.key("nodes"), node_name]
           ]),
         :ok <- Results.expect_no_redis_errors(results),
         :ok <- Connection.wait_for_replicas() do
      {:ok, state}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def fetch_node_state(node_name) do
    case Connection.command(["GET", Keys.key("node", node_name, "state")]) do
      {:ok, nil} ->
        {:error, "node #{node_name} state was not found"}

      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, state} when is_map(state) -> {:ok, state}
          {:ok, _invalid} -> {:error, :invalid_node_state}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def list_node_states do
    case Connection.command(["SMEMBERS", Keys.key("nodes")]) do
      {:ok, node_names} ->
        node_names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, [], false}, &collect_node_state/2)
        |> finish_node_state_listing()

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  defp collect_node_state(node_name, {:ok, states, removed_stale?}) do
    case fetch_node_state(node_name) do
      {:ok, state} ->
        {:cont, {:ok, [state | states], removed_stale?}}

      {:error, reason} ->
        cond do
          missing_node_state?(node_name, reason) ->
            case Connection.command(["SREM", Keys.key("nodes"), node_name]) do
              {:ok, removed} when is_integer(removed) ->
                {:cont, {:ok, states, removed_stale? or removed > 0}}

              {:error, cleanup_reason} ->
                {:halt, {:error, Values.format_reason(cleanup_reason)}}

              other ->
                {:halt, {:error, Values.format_reason(other)}}
            end

          corrupt_node_state?(reason) ->
            Logger.debug("ignoring unreadable node state #{node_name}: #{inspect(reason)}")
            {:cont, {:ok, states, removed_stale?}}

          true ->
            {:halt, {:error, Values.format_reason(reason)}}
        end
    end
  end

  defp finish_node_state_listing({:ok, states, false}), do: {:ok, Enum.reverse(states)}

  defp finish_node_state_listing({:ok, states, true}) do
    with :ok <- Connection.wait_for_replicas(), do: {:ok, Enum.reverse(states)}
  end

  defp finish_node_state_listing({:error, _reason} = error), do: error

  defp missing_node_state?(node_name, reason),
    do: reason == "node #{node_name} state was not found"

  defp corrupt_node_state?(:invalid_node_state), do: true

  defp corrupt_node_state?(reason), do: Values.corrupt_json?(reason)
end
