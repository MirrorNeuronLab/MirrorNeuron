defmodule MirrorNeuron.Cluster.Reconciler.NodeAvailability do
  @moduledoc "Checks disconnect grace windows against durable node state."

  alias MirrorNeuron.Cluster.Reconciler.Options
  alias MirrorNeuron.Cluster.Reconciler.Timing

  def disconnected_grace_active?(nil, _opts), do: false

  def disconnected_grace_active?(node, opts) do
    node_status = Keyword.get(opts, :node_status)
    wait_until = disconnected_wait_until(node, opts)

    cond do
      node_status == "disconnected" ->
        is_nil(wait_until) or not Timing.wait_due?(wait_until)

      true ->
        case fetch_node_state(node, opts) do
          {:ok, %{"status" => "disconnected"} = state} ->
            state_wait_until =
              Map.get(state, "disconnect_expires_at") ||
                Map.get(state, "wait_until") ||
                Map.get(state, "recovery_wait_until")

            is_nil(state_wait_until) or not Timing.wait_due?(state_wait_until)

          _ ->
            false
        end
    end
  end

  def disconnected_wait_until(node, opts) do
    Keyword.get(opts, :wait_until) ||
      Keyword.get(opts, :disconnect_expires_at) ||
      case fetch_node_state(node, opts) do
        {:ok, state} ->
          Map.get(state, "disconnect_expires_at") ||
            Map.get(state, "wait_until") ||
            Map.get(state, "recovery_wait_until")

        _ ->
          nil
      end
  end

  defp fetch_node_state(node, opts) do
    store = Options.redis_store(opts)

    cond do
      function_exported?(store, :fetch_node_state, 1) ->
        store.fetch_node_state(Options.node_name(node))

      Keyword.has_key?(opts, :redis_store) ->
        {:error, :node_state_unavailable}

      true ->
        MirrorNeuron.Cluster.NodeState.fetch(node)
    end
  rescue
    _ -> {:error, :node_state_unavailable}
  catch
    _kind, _reason -> {:error, :node_state_unavailable}
  end
end
