defmodule MirrorNeuron.Runtime.EventBus do
  alias MirrorNeuron.Persistence.RedisStore

  def subscribe(job_id) do
    Registry.register(MirrorNeuron.Runtime.EventRegistry, job_id, [])
  end

  def publish(job_id, event) do
    persisted = Map.put_new(event, :job_id, job_id)
    RedisStore.append_event(job_id, stringify_keys(persisted))

    Registry.dispatch(MirrorNeuron.Runtime.EventRegistry, job_id, fn entries ->
      Enum.each(entries, fn {pid, _value} -> send(pid, {:mirror_neuron_event, persisted}) end)
    end)

    :ok
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
