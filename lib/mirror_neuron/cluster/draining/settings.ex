defmodule MirrorNeuron.Cluster.NodeDrainer.Settings do
  @moduledoc "Drain dependencies, time boundaries and validated option values."

  alias MirrorNeuron.Runtime.EventBus
  alias MirrorNeuron.Cluster.NodeState
  alias MirrorNeuron.Cluster.Reconciler
  alias MirrorNeuron.Persistence.RedisStore

  @default_deadline_ms 1_800_000

  def due_drain_state?(%{"status" => "draining", "drain" => %{"status" => status}})
      when status in ["draining", "blocked_no_placement"],
      do: true

  def due_drain_state?(_state), do: false

  def list_jobs(opts) do
    store = redis_store(opts)

    if function_exported?(store, :list_jobs, 0) do
      store.list_jobs()
    else
      {:ok, []}
    end
  end

  def list_node_states(opts) do
    node_state = node_state_module(opts)
    store = redis_store(opts)

    cond do
      function_exported?(node_state, :list, 0) ->
        {:ok, node_state.list()}

      function_exported?(store, :list_node_states, 0) ->
        store.list_node_states()

      true ->
        {:ok, []}
    end
  end

  def deadline_due?(deadline_at) do
    case DateTime.from_iso8601(to_string(deadline_at)) do
      {:ok, deadline, _offset} -> DateTime.compare(deadline, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  def iso_after(delay_ms) do
    DateTime.utc_now()
    |> DateTime.add(integer_value(delay_ms, @default_deadline_ms), :millisecond)
    |> DateTime.to_iso8601()
  end

  def json_safe(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  def json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)

  def json_safe(value), do: value

  def option(opts, key, default \\ nil) do
    MirrorNeuron.SafeAccess.keyword_get(opts, key, default)
  end

  def maybe_put(map, _key, nil), do: map

  def maybe_put(map, key, value), do: Map.put(map, key, value)

  defp integer_value(value, _default) when is_integer(value) and value >= 0, do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default

  def node_state_module(opts), do: Keyword.get(opts, :node_state, NodeState)

  defp redis_store(opts), do: Keyword.get(opts, :redis_store, RedisStore)

  def reconciler(opts), do: Keyword.get(opts, :reconciler, Reconciler)

  def event_bus(opts), do: Keyword.get(opts, :event_bus, EventBus)

  def node_name(node) when is_atom(node), do: Atom.to_string(node)

  def node_name(node) when is_binary(node), do: node

  def node_name(node), do: to_string(node)
end
