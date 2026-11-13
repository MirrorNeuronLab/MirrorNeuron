defmodule MirrorNeuron.Builtins.Executor.Leases do
  @moduledoc "Normalizes executor pool requests and bounded admission options."

  alias MirrorNeuron.Execution.LeaseManager
  alias MirrorNeuron.Execution.Profile

  def configured_pool(config) do
    config
    |> Map.get("pool", "default")
    |> to_string()
  end

  def configured_pool_slots(config) do
    case Map.get(config, "pool_slots", 1) do
      slots when is_integer(slots) and slots > 0 -> slots
      _ -> 1
    end
  end

  def configured_lease_manager(config) do
    Map.get(config, "lease_manager") || Map.get(config, :lease_manager) || LeaseManager
  end

  def configured_lease_opts(config) do
    []
    |> maybe_put_int(:queue_timeout_ms, Map.get(config, "lease_queue_timeout_ms"))
    |> maybe_put_int(:queue_timeout_ms, Map.get(config, :lease_queue_timeout_ms))
    |> maybe_put_int(:max_queue_length, Map.get(config, "lease_max_queue_length"))
    |> maybe_put_int(:max_queue_length, Map.get(config, :lease_max_queue_length))
  end

  def lease_metadata(context) do
    %{
      job_id: context.job_id,
      agent_id: context.node.node_id,
      node: to_string(Node.self()),
      execution_profile: Profile.profile_name(Map.get(context.node, :config, %{}))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put_int(opts, _key, nil), do: opts

  defp maybe_put_int(opts, key, value) when is_integer(value) and value >= 0 do
    Keyword.put(opts, key, value)
  end

  defp maybe_put_int(opts, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> Keyword.put(opts, key, parsed)
      _ -> opts
    end
  end

  defp maybe_put_int(opts, _key, _value), do: opts
end
