defmodule MirrorNeuron.Persistence.RedisStore.ServiceIndex do
  @moduledoc "Service ownership selectors and stale secondary-index reclamation."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Values

  @service_index_fields [
    {:name, "name"},
    {:job_id, "job"},
    {:node, "node"},
    {:agent_id, "agent"}
  ]

  def purge_missing_service_instance(instance_id) do
    with {:ok, index_keys} <- service_secondary_index_keys() do
      purge_missing_service_instance(instance_id, index_keys)
    end
  end

  def purge_missing_service_instance(instance_id, index_keys) do
    script = """
    if redis.call("exists", KEYS[1]) ~= 0 then
      return 0
    end

    redis.call("srem", KEYS[2], ARGV[1])

    for index = 3, #KEYS do
      redis.call("srem", KEYS[index], ARGV[1])
    end

    return 1
    """

    keys = [
      Keys.key("service", "instance", instance_id),
      Keys.key("service", "instances") | index_keys
    ]

    case Connection.command(["EVAL", script, to_string(length(keys)) | keys ++ [instance_id]]) do
      {:ok, result} when result in [0, 1] ->
        with :ok <- Connection.maybe_wait_for_deleted_keys(result), do: {:ok, result}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}

      other ->
        {:error, Values.format_reason(other)}
    end
  end

  def service_secondary_index_keys do
    @service_index_fields
    |> Enum.reduce_while({:ok, []}, fn {_option, index}, {:ok, keys} ->
      case Connection.scan_keys(Keys.key("service", index, "*")) do
        {:ok, found} -> {:cont, {:ok, found ++ keys}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.uniq(keys)}
      {:error, _reason} = error -> error
    end
  end

  def sweep_service_instance_index do
    with {:ok, secondary_keys} <- service_secondary_index_keys(),
         index_keys <- [Keys.key("service", "instances") | secondary_keys],
         {:ok, indexed_ids} <- service_index_ids(index_keys),
         {:ok, existence} <- service_instance_existence(indexed_ids),
         :ok <- Results.expect_no_redis_errors(existence),
         stale <- stale_service_instance_ids(indexed_ids, existence),
         {:ok, removed} <- purge_stale_service_instances(stale, secondary_keys) do
      removed = Enum.sort(removed)

      {:ok,
       %{
         stale_service_instance_count: length(removed),
         stale_service_instances: removed
       }}
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
      other -> {:error, Values.format_reason(other)}
    end
  end

  defp service_index_ids(index_keys) do
    case Connection.pipeline(Enum.map(index_keys, &["SMEMBERS", &1])) do
      {:ok, results} ->
        with :ok <- Results.expect_no_redis_errors(results) do
          {:ok, results |> Enum.flat_map(& &1) |> Enum.uniq() |> Enum.sort()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp service_instance_existence([]), do: {:ok, []}

  defp service_instance_existence(instance_ids) do
    Connection.pipeline(Enum.map(instance_ids, &["EXISTS", Keys.key("service", "instance", &1)]))
  end

  defp stale_service_instance_ids(instance_ids, existence) do
    instance_ids
    |> Enum.zip(existence)
    |> Enum.flat_map(fn
      {instance_id, 0} -> [instance_id]
      {_instance_id, 1} -> []
    end)
  end

  defp purge_stale_service_instances(instance_ids, index_keys) do
    Enum.reduce_while(instance_ids, {:ok, []}, fn instance_id, {:ok, removed} ->
      case purge_missing_service_instance(instance_id, index_keys) do
        {:ok, 1} -> {:cont, {:ok, [instance_id | removed]}}
        {:ok, 0} -> {:cont, {:ok, removed}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      {:error, _reason} = error -> error
    end
  end

  def service_index_script_args(service) do
    Enum.flat_map(@service_index_fields, fn {option, index} ->
      field = Atom.to_string(option)
      value = Map.get(service, field)
      value = if is_binary(value), do: value, else: ""
      [field, Keys.key("service", index, ""), value]
    end)
  end

  def service_selector_script_args(opts) do
    Enum.flat_map(opts, fn {option, value} ->
      case List.keyfind(@service_index_fields, option, 0) do
        {_option, index} ->
          [Atom.to_string(option), to_string(value), Keys.key("service", index, to_string(value))]

        nil ->
          []
      end
    end)
  end

  def service_index_prefix_script_args do
    Enum.flat_map(@service_index_fields, fn {option, index} ->
      [Atom.to_string(option), Keys.key("service", index, "")]
    end)
  end
end
