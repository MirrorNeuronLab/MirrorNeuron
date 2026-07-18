defmodule MirrorNeuron.Persistence.OperationStore do
  @moduledoc false

  alias MirrorNeuron.Config

  @terminal_statuses ["completed", "completed_with_failures", "failed"]
  @event_ttl_seconds 7 * 24 * 60 * 60

  def create(kind, targets, attrs \\ %{}) when is_binary(kind) and is_list(targets) do
    operation_id = "op-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    now = timestamp()

    operation =
      %{
        "operation_id" => operation_id,
        "kind" => kind,
        "status" => "pending",
        "targets" => targets,
        "target_count" => length(targets),
        "counters" => empty_counters(length(targets)),
        "created_at" => now,
        "updated_at" => now,
        "started_at" => nil,
        "completed_at" => nil,
        "errors" => []
      }
      |> Map.merge(stringify(attrs))

    with {:ok, "OK"} <- command(["SET", operation_key(operation_id), Jason.encode!(operation)]),
         {:ok, _} <- command(["SADD", operations_key(), operation_id]),
         {:ok, _event} <- append_event(operation_id, %{"type" => "operation_created"}) do
      {:ok, operation}
    end
  end

  def fetch(operation_id) when is_binary(operation_id) do
    with {:ok, encoded} when is_binary(encoded) <- command(["GET", operation_key(operation_id)]),
         {:ok, operation} <- Jason.decode(encoded) do
      {:ok, hydrate(operation)}
    else
      {:ok, nil} -> {:error, "operation #{operation_id} was not found"}
      {:error, _reason} = error -> error
      _ -> {:error, "operation #{operation_id} is invalid"}
    end
  end

  def fetch(_operation_id), do: {:error, "operation_id must be a non-empty string"}

  def list_unfinished do
    with {:ok, ids} <- command(["SMEMBERS", operations_key()]) do
      ids
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, operations} ->
        case fetch(id) do
          {:ok, %{"status" => status} = operation} when status not in @terminal_statuses ->
            {:cont, {:ok, [operation | operations]}}

          {:ok, _operation} ->
            {:cont, {:ok, operations}}

          {:error, reason} when is_binary(reason) ->
            if String.contains?(reason, "was not found"),
              do: {:cont, {:ok, operations}},
              else: {:halt, {:error, reason}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, operations} -> {:ok, Enum.reverse(operations)}
        other -> other
      end
    end
  end

  def update(operation_id, fun) when is_function(fun, 1) do
    with {:ok, operation} <- fetch(operation_id),
         next when is_map(next) <- fun.(operation),
         next <- Map.put(next, "updated_at", timestamp()),
         {:ok, "OK"} <-
           command(["SET", operation_key(operation_id), Jason.encode!(dehydrate(next))]) do
      {:ok, hydrate(next)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, "operation update must return a map"}
    end
  end

  def start_item(operation_id, target) when is_map(target) do
    item_id = target_id(target)
    now = timestamp()

    item = %{
      "item_id" => item_id,
      "target" => target,
      "status" => "running",
      "started_at" => now,
      "completed_at" => nil,
      "result" => nil,
      "error" => nil
    }

    with {:ok, "OK"} <- command(["SET", item_key(operation_id, item_id), Jason.encode!(item)]),
         {:ok, _} <- command(["SADD", items_key(operation_id), item_id]),
         {:ok, event} <-
           append_event(operation_id, %{
             "type" => "item_started",
             "item_id" => item_id,
             "target" => target
           }) do
      {:ok, item, event}
    end
  end

  def finish_item(operation_id, target, status, result \\ %{}, error \\ nil)
      when is_map(target) and is_binary(status) do
    item_id = target_id(target)
    now = timestamp()

    item = %{
      "item_id" => item_id,
      "target" => target,
      "status" => status,
      "started_at" => now,
      "completed_at" => now,
      "result" => stringify(result),
      "error" => normalize_error(error)
    }

    event_type =
      if status in ["deferred", "cancellation_pending"],
        do: "item_deferred",
        else: "item_completed"

    with {:ok, "OK"} <- command(["SET", item_key(operation_id, item_id), Jason.encode!(item)]),
         {:ok, _} <- command(["SADD", items_key(operation_id), item_id]),
         {:ok, event} <-
           append_event(operation_id, %{
             "type" => event_type,
             "item_id" => item_id,
             "status" => status,
             "result" => stringify(result),
             "error" => normalize_error(error)
           }) do
      {:ok, item, event}
    end
  end

  def append_event(operation_id, event) when is_map(event) do
    with {:ok, sequence} <- command(["INCR", event_sequence_key(operation_id)]) do
      event =
        event
        |> stringify()
        |> Map.put("operation_id", operation_id)
        |> Map.put("sequence", sequence)
        |> Map.put_new("timestamp", timestamp())

      encoded = Jason.encode!(event)

      with {:ok, _} <- command(["RPUSH", events_key(operation_id), encoded]),
           {:ok, _} <-
             command(["EXPIRE", events_key(operation_id), Integer.to_string(@event_ttl_seconds)]),
           {:ok, _} <- command(["PUBLISH", events_channel(operation_id), encoded]) do
        {:ok, event}
      end
    end
  end

  def read_events(operation_id, after_sequence \\ 0) do
    with {:ok, encoded_events} <- command(["LRANGE", events_key(operation_id), "0", "-1"]) do
      events =
        encoded_events
        |> Enum.flat_map(fn encoded ->
          case Jason.decode(encoded) do
            {:ok, event} when is_map(event) -> [event]
            _ -> []
          end
        end)
        |> Enum.filter(&(event_sequence(&1) > after_sequence))

      {:ok, events}
    end
  end

  def claim_runner(operation_id, owner, ttl_ms \\ 30_000) do
    case command(["SET", runner_key(operation_id), owner, "NX", "PX", Integer.to_string(ttl_ms)]) do
      {:ok, "OK"} -> :ok
      {:ok, nil} -> {:error, :claimed}
      {:error, _reason} = error -> error
    end
  end

  def release_runner(operation_id, owner) do
    script = """
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    end
    return 0
    """

    case command(["EVAL", script, "1", runner_key(operation_id), owner]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def renew_runner(operation_id, owner, ttl_ms \\ 30_000) do
    script = """
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("pexpire", KEYS[1], ARGV[2])
    end
    return 0
    """

    case command([
           "EVAL",
           script,
           "1",
           runner_key(operation_id),
           owner,
           Integer.to_string(ttl_ms)
         ]) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :not_owner}
      {:error, _reason} = error -> error
    end
  end

  def terminal?(%{"status" => status}), do: status in @terminal_statuses
  def terminal?(_operation), do: false

  def item_statuses(operation) do
    operation
    |> Map.get("items", %{})
    |> Map.values()
    |> Enum.map(&Map.get(&1, "status"))
  end

  def counters(operation) do
    statuses = item_statuses(operation)
    total = Map.get(operation, "target_count", 0)

    Enum.reduce(statuses, empty_counters(total), fn status, counters ->
      counters
      |> Map.update!("finished", &(&1 + 1))
      |> bump_counter(status)
    end)
    |> Map.put("started", length(statuses))
  end

  def operation_key(operation_id), do: key("operation", operation_id)

  defp hydrate(operation) do
    operation
    |> Map.put("items", read_items(Map.fetch!(operation, "operation_id")))
    |> then(fn hydrated -> Map.put(hydrated, "counters", counters(hydrated)) end)
  end

  defp dehydrate(operation), do: Map.delete(operation, "items")

  defp read_items(operation_id) do
    case command(["SMEMBERS", items_key(operation_id)]) do
      {:ok, ids} ->
        ids
        |> Enum.reduce(%{}, fn item_id, items ->
          case command(["GET", item_key(operation_id, item_id)]) do
            {:ok, encoded} when is_binary(encoded) ->
              case Jason.decode(encoded) do
                {:ok, item} -> Map.put(items, item_id, item)
                _ -> items
              end

            _ ->
              items
          end
        end)

      _ ->
        %{}
    end
  end

  defp target_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp target_id(%{"job_id" => id}) when is_binary(id) and id != "", do: id
  defp target_id(%{"node_name" => id}) when is_binary(id) and id != "", do: id
  defp target_id(target), do: "target-" <> Integer.to_string(:erlang.phash2(target))

  defp empty_counters(total),
    do: %{
      "total" => total,
      "started" => 0,
      "finished" => 0,
      "succeeded" => 0,
      "failed" => 0,
      "deferred" => 0,
      "skipped" => 0
    }

  defp bump_counter(counters, "failed"), do: Map.update!(counters, "failed", &(&1 + 1))

  defp bump_counter(counters, status)
       when status in ["deferred", "cancellation_pending", "waiting"],
       do: Map.update!(counters, "deferred", &(&1 + 1))

  defp bump_counter(counters, status) when status in ["skipped", "ignored"],
    do: Map.update!(counters, "skipped", &(&1 + 1))

  defp bump_counter(counters, _status), do: Map.update!(counters, "succeeded", &(&1 + 1))

  defp event_sequence(event), do: Map.get(event, "sequence", 0)
  defp normalize_error(nil), do: nil
  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {if(is_atom(key), do: Atom.to_string(key), else: key), stringify(value)}
    end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp command(args) do
    case Redix.command(MirrorNeuron.Redis.Connection, args) do
      {:error, reason} -> {:error, inspect(reason)}
      result -> result
    end
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp operations_key, do: key("operations")
  defp items_key(operation_id), do: key("operation", operation_id, "items")
  defp item_key(operation_id, item_id), do: key("operation", operation_id, "item", item_id)
  defp events_key(operation_id), do: key("operation", operation_id, "events")
  defp event_sequence_key(operation_id), do: key("operation", operation_id, "event_sequence")
  defp events_channel(operation_id), do: key("channel", "operations", operation_id)
  defp runner_key(operation_id), do: key("operation", operation_id, "runner")
  defp key(part1), do: Enum.join([namespace(), part1], ":")
  defp key(part1, part2), do: Enum.join([namespace(), part1, part2], ":")
  defp key(part1, part2, part3), do: Enum.join([namespace(), part1, part2, part3], ":")

  defp key(part1, part2, part3, part4),
    do: Enum.join([namespace(), part1, part2, part3, part4], ":")

  defp namespace, do: Config.string("MN_REDIS_NAMESPACE", :redis_namespace)

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
