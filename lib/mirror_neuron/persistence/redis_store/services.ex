defmodule MirrorNeuron.Persistence.RedisStore.Services do
  @moduledoc "Service discovery records and conditional owner-scoped deletion."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.ServiceIndex
  alias MirrorNeuron.Persistence.RedisStore.Values

  @service_index_fields [
    {:name, "name"},
    {:job_id, "job"},
    {:node, "node"},
    {:agent_id, "agent"}
  ]

  def persist_service_instance(instance_id, service_map) do
    write_service_instance(instance_id, service_map, false)
  end

  def update_service_instance_if_exists(instance_id, service_map) do
    write_service_instance(instance_id, service_map, true)
  end

  defp write_service_instance(instance_id, service_map, require_existing?) do
    service =
      service_map
      |> Values.stringify_map()
      |> Map.put("id", instance_id)
      |> Map.put_new("created_at", Values.timestamp())
      |> Map.put("updated_at", Values.timestamp())

    script = """
    local existing = redis.call("get", KEYS[1])

    if ARGV[3] == "1" and not existing then
      return 0
    end

    if existing then
      local ok, decoded = pcall(cjson.decode, existing)

      if not ok or type(decoded) ~= "table" or tostring(decoded["id"]) ~= ARGV[1] then
        return redis.error_reply("invalid existing service instance " .. ARGV[1])
      end

      for index = 4, #ARGV, 3 do
        local old_value = decoded[ARGV[index]]

        if type(old_value) == "string" and old_value ~= "" then
          redis.call("srem", ARGV[index + 1] .. old_value, ARGV[1])
        end
      end
    end

    redis.call("set", KEYS[1], ARGV[2])
    redis.call("sadd", KEYS[2], ARGV[1])

    for index = 4, #ARGV, 3 do
      local new_value = ARGV[index + 2]

      if new_value ~= "" then
        redis.call("sadd", ARGV[index + 1] .. new_value, ARGV[1])
      end
    end

    return 1
    """

    args =
      [
        "EVAL",
        script,
        "2",
        Keys.key("service", "instance", instance_id),
        Keys.key("service", "instances"),
        instance_id,
        Jason.encode!(service),
        if(require_existing?, do: "1", else: "0")
      ] ++ ServiceIndex.service_index_script_args(service)

    case Connection.command(args) do
      {:ok, 1} ->
        with :ok <- Connection.wait_for_replicas(), do: {:ok, service}

      {:ok, 0} ->
        {:error, "service instance #{instance_id} was not found"}

      {:error, reason} ->
        {:error, Values.format_reason(reason)}

      other ->
        {:error, Values.format_reason(other)}
    end
  end

  def fetch_service_instance(instance_id) do
    case Connection.command(["GET", Keys.key("service", "instance", instance_id)]) do
      {:ok, nil} ->
        {:error, "service instance #{instance_id} was not found"}

      {:ok, encoded} ->
        case Jason.decode(encoded) do
          {:ok, service} when is_map(service) -> {:ok, service}
          {:ok, _invalid} -> {:error, :invalid_service_instance}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  def list_service_instances(_opts \\ []) do
    case Connection.command(["SMEMBERS", Keys.key("service", "instances")]) do
      {:ok, ids} -> fetch_service_instances(Enum.sort(ids))
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def delete_service_instance(instance_id),
    do: delete_service_instance_if_matches(instance_id, [])

  def delete_service_instances(opts) when is_list(opts) do
    with {:ok, instance_ids} <- service_candidate_ids(opts) do
      Enum.reduce_while(instance_ids, :ok, fn instance_id, :ok ->
        continue_service_cleanup(delete_service_instance_if_matches(instance_id, opts))
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_service_instances([]), do: {:ok, []}

  defp fetch_service_instances(instance_ids) do
    keys = Enum.map(instance_ids, &Keys.key("service", "instance", &1))

    case Connection.command(["MGET" | keys]) do
      {:ok, encoded_services} ->
        instance_ids
        |> Enum.zip(encoded_services)
        |> Enum.reduce_while({:ok, []}, fn
          {instance_id, nil}, {:ok, services} ->
            case ServiceIndex.purge_missing_service_instance(instance_id) do
              {:ok, _result} -> {:cont, {:ok, services}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {instance_id, encoded}, {:ok, services} ->
            case Jason.decode(encoded) do
              {:ok, service} when is_map(service) ->
                {:cont, {:ok, [service | services]}}

              {:error, reason} ->
                Logger.debug(
                  "ignoring unreadable service instance #{instance_id}: #{inspect(reason)}"
                )

                {:cont, {:ok, services}}

              {:ok, _invalid} ->
                Logger.debug("ignoring invalid service instance #{instance_id}")
                {:cont, {:ok, services}}
            end
        end)
        |> case do
          {:ok, services} -> {:ok, Enum.reverse(services)}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, Values.format_reason(reason)}
    end
  end

  defp service_candidate_ids(opts) do
    selector_keys = service_selector_index_keys(opts)

    cond do
      opts == [] ->
        Connection.command(["SMEMBERS", Keys.key("service", "instances")])

      selector_keys == [] ->
        {:error, :invalid_service_filter}

      length(selector_keys) == 1 ->
        Connection.command(["SMEMBERS", hd(selector_keys)])

      true ->
        Connection.command(["SINTER" | selector_keys])
    end
  end

  defp service_selector_index_keys(opts) do
    opts
    |> Enum.flat_map(fn {option, value} ->
      case List.keyfind(@service_index_fields, option, 0) do
        {_option, index} -> [Keys.key("service", index, to_string(value))]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  defp continue_service_cleanup(:ok), do: {:cont, :ok}

  defp continue_service_cleanup({:error, reason}), do: {:halt, {:error, reason}}

  defp delete_service_instance_if_matches(instance_id, opts) do
    with {:ok, index_keys} <- ServiceIndex.service_secondary_index_keys() do
      script = """
      local encoded = redis.call("get", KEYS[1])
      local should_delete = true
      local selector_count = tonumber(ARGV[2])
      local service = nil

      if encoded then
        local ok, decoded = pcall(cjson.decode, encoded)

        if ok and type(decoded) == "table" then
          service = decoded

          for index = 3, 2 + selector_count * 3, 3 do
            local value = service[ARGV[index]]

            if type(value) ~= "string" or value ~= ARGV[index + 1] then
              should_delete = false
            end
          end
        end
      end

      if should_delete then
        redis.call("del", KEYS[1])
        redis.call("srem", KEYS[2], ARGV[1])

        for index = 3, #KEYS do
          redis.call("srem", KEYS[index], ARGV[1])
        end

        if service then
          for index = 3 + selector_count * 3, #ARGV, 2 do
            local value = service[ARGV[index]]

            if type(value) == "string" and value ~= "" then
              redis.call("srem", ARGV[index + 1] .. value, ARGV[1])
            end
          end
        end

        return 1
      end

      for index = 3, 2 + selector_count * 3, 3 do
        redis.call("srem", ARGV[index + 2], ARGV[1])
      end

      return 0
      """

      keys = [
        Keys.key("service", "instance", instance_id),
        Keys.key("service", "instances") | index_keys
      ]

      selector_args = ServiceIndex.service_selector_script_args(opts)

      args =
        [instance_id, to_string(div(length(selector_args), 3))] ++
          selector_args ++ ServiceIndex.service_index_prefix_script_args()

      case Connection.command(["EVAL", script, to_string(length(keys)) | keys ++ args]) do
        {:ok, result} when result in [0, 1] -> Connection.maybe_wait_for_deleted_keys(result)
        {:error, reason} -> {:error, Values.format_reason(reason)}
        other -> {:error, Values.format_reason(other)}
      end
    end
  end
end
