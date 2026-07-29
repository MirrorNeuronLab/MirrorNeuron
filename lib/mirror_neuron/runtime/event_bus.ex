defmodule MirrorNeuron.Runtime.EventBus do
  require Logger

  alias MirrorNeuron.Persistence.RedisStore

  def subscribe(job_id) do
    Registry.register(MirrorNeuron.Runtime.EventRegistry, job_id, [])
  end

  def publish(job_id, event) do
    persisted = Map.put_new(event, :job_id, job_id)

    if safe_append_event(job_id, json_safe(persisted)) != :job_cleared do
      dispatch(job_id, persisted)
    end

    :ok
  end

  def publish_if_job_exists(job_id, event) do
    persisted = Map.put_new(event, :job_id, job_id)

    case safe_append_event_if_job_exists(job_id, json_safe(persisted)) do
      :persisted ->
        dispatch(job_id, persisted)

      :job_missing ->
        :ok
    end

    :ok
  end

  defp safe_append_event(job_id, event) do
    case RedisStore.append_event(job_id, event) do
      {:ok, :job_cleared} ->
        :job_cleared

      {:ok, _event} ->
        :persisted

      {:error, reason} ->
        Logger.warning("failed to persist event for #{job_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("failed to persist event for #{job_id}: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("failed to persist event for #{job_id}: #{kind} #{inspect(reason)}")
      :ok
  end

  defp dispatch(job_id, event) do
    Registry.dispatch(MirrorNeuron.Runtime.EventRegistry, job_id, fn entries ->
      Enum.each(entries, fn {pid, _value} -> send(pid, {:mirror_neuron_event, event}) end)
    end)
  end

  defp safe_append_event_if_job_exists(job_id, event) do
    case RedisStore.append_event_if_job_exists(job_id, event) do
      {:ok, :job_missing} ->
        :job_missing

      {:ok, _event} ->
        :persisted

      {:error, reason} ->
        Logger.warning("failed to persist event for #{job_id}: #{inspect(reason)}")
        :job_missing
    end
  rescue
    error ->
      Logger.warning("failed to persist event for #{job_id}: #{Exception.message(error)}")
      :job_missing
  catch
    kind, reason ->
      Logger.warning("failed to persist event for #{job_id}: #{kind} #{inspect(reason)}")
      :job_missing
  end

  defp json_safe(%_struct{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, json_safe(value)}
    end)
  end

  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_pid(value), do: inspect(value)
  defp json_safe(value) when is_reference(value), do: inspect(value)
  defp json_safe(value) when is_function(value), do: inspect(value)
  defp json_safe(value), do: value
end
