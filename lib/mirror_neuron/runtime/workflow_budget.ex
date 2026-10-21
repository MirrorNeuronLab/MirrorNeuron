defmodule MirrorNeuron.Runtime.WorkflowBudget do
  @moduledoc "Core-owned, durable action admission for one actual workflow run."

  alias MirrorNeuron.Runtime.Naming
  @schema "mn.workflow_budget/v1"
  @max_records 100_000
  @max_journal_bytes 4_000_000
  @identity_fields ~w(action_type stage entity_id tool scope revision)

  def validate_declarations(policies) when is_map(policies) do
    case Map.get(policies, "workflow_budgets") do
      nil ->
        :ok

      declarations when is_map(declarations) and map_size(declarations) in 1..32 ->
        if Enum.all?(declarations, fn {name, value} ->
             valid_name?(name) and is_map(value) and Map.keys(value) == ["limit"] and
               is_integer(value["limit"]) and value["limit"] in 0..100_000
           end), do: :ok, else: {:error, "invalid workflow budget declaration"}

      _ ->
        {:error, "invalid workflow budget declarations"}
    end
  end

  def validate_declarations(_), do: {:error, "workflow policies must be an object"}

  def validation_errors(policies) do
    case validate_declarations(policies) do
      :ok -> []
      {:error, reason} -> [reason]
    end
  end

  def command(attrs, opts \\ []) do
    with :ok <- validate_request(attrs) do
      lookup = Keyword.get(opts, :owner, &Naming.via_job/1)

      try do
        GenServer.call(lookup.(attrs["job_id"]), {:workflow_budget, attrs}, 10_000)
      catch
        :exit, _ -> {:error, "workflow budget owner is unavailable"}
      end
    end
  end

  def apply_command(state, policies, run_id, attrs, persist) when is_function(persist, 1) do
    with {:ok, response, next} <- transition(state, policies, run_id, attrs),
         :ok <- persist_if_changed(state, next, persist) do
      {:ok, response, next}
    end
  end

  def transition(state, policies, run_id, attrs, now \\ nil) do
    now = now || DateTime.to_iso8601(DateTime.utc_now())

    with :ok <- validate_request(attrs),
         :ok <- validate_declarations(policies),
         true <- is_binary(run_id) and attrs["run_id"] == run_id,
         %{"limit" => limit} <- get_in(policies, ["workflow_budgets", attrs["name"]]),
         true <- attrs["limit"] == limit,
         :ok <- validate_state(state, run_id),
         pool <-
           get_in(state, ["pools", attrs["name"]]) ||
             %{"limit" => limit, "used" => 0, "actions" => %{}},
         :ok <- validate_pool(pool, limit),
         {:ok, response, next_pool} <- dispatch(pool, attrs, now) do
      next = state |> Map.put("run_id", run_id) |> Map.put_new("pools", %{})
      next = put_in(next, ["pools", attrs["name"]], next_pool)

      {:ok,
       Map.merge(response, %{
         "schema" => @schema,
         "name" => attrs["name"],
         "run_id" => run_id,
         "job_id" => attrs["job_id"]
       }), next}
    else
      {:error, _} = error -> error
      _ -> {:error, "workflow budget run, declaration or allowance changed"}
    end
  end

  defp dispatch(pool, %{"action" => "summary"}, _now), do: {:ok, summary(pool), pool}

  defp dispatch(pool, %{"action" => "start"} = attrs, now) do
    id = attrs["request_id"]
    request = Map.take(attrs, @identity_fields ++ ["metadata"])

    case pool["actions"][id] do
      %{"request" => ^request} = record ->
        {:ok, admission(pool, record), pool}

      record when is_map(record) ->
        {:error, "workflow budget request changed during replay"}

      nil ->
        if map_size(pool["actions"]) >= @max_records do
          {:error, "workflow budget record capacity exceeded"}
        else
          cost = if pool["used"] < pool["limit"], do: 1, else: 0

          action =
            request
            |> Map.merge(%{
              "reservation_id" => id,
              "action_index" => map_size(pool["actions"]) + 1,
              "cost" => cost,
              "budget" => pool["limit"],
              "used" => pool["used"] + cost,
              "remaining" => max(0, pool["limit"] - pool["used"] - cost),
              "status" => if(cost == 1, do: "started", else: "budget_exhausted"),
              "recorded_at" => now
            })

          record = %{"request" => request, "action" => action}

          next = %{
            pool
            | "used" => pool["used"] + cost,
              "actions" => Map.put(pool["actions"], id, record)
          }

          bounded_pool(next, admission(next, record))
        end
    end
  end

  defp dispatch(pool, %{"action" => "complete"} = attrs, now) do
    case pool["actions"][attrs["request_id"]] do
      %{"action" => %{"cost" => 1}, "request" => request} = record ->
        if request["scope"] != attrs["scope"] or request["revision"] != attrs["revision"] do
          {:error, "workflow budget reservation belongs to another worker scope"}
        else
          completion = Map.take(attrs, ["status", "metadata"])

          case record["completion"] do
            ^completion ->
              {:ok, completion_receipt(attrs), pool}

            nil ->
              action =
                record["action"]
                |> Map.merge(%{
                  "status" => attrs["status"],
                  "completed_at" => now,
                  "metadata" => Map.merge(record["action"]["metadata"], attrs["metadata"])
                })

              record = Map.merge(record, %{"action" => action, "completion" => completion})

              bounded_pool(
                put_in(pool, ["actions", attrs["request_id"]], record),
                completion_receipt(attrs)
              )

            _ ->
              {:error, "workflow budget completion changed during replay"}
          end
        end

      _ ->
        {:error, "unknown workflow budget reservation"}
    end
  end

  defp completion_receipt(attrs),
    do: %{"status" => "completed", "request_id" => attrs["request_id"], "scope" => attrs["scope"]}

  defp admission(pool, record),
    do: %{
      "status" => if(record["action"]["cost"] == 1, do: "admitted", else: "budget_exhausted"),
      "action" => record["action"],
      "request" => record["request"],
      "budget" => pool["limit"],
      "used" => pool["used"]
    }

  defp summary(pool),
    do: %{
      "budget" => pool["limit"],
      "used" => pool["used"],
      "remaining" => max(0, pool["limit"] - pool["used"]),
      "exhausted" => pool["used"] >= pool["limit"],
      "actions" =>
        pool["actions"]
        |> Map.values()
        |> Enum.map(& &1["action"])
        |> Enum.sort_by(& &1["action_index"])
    }

  defp validate_request(attrs) when is_map(attrs) do
    common = ~w(operation schema action job_id run_id name limit)

    allowed =
      case attrs["action"] do
        "start" -> common ++ @identity_fields ++ ~w(request_id metadata)
        "complete" -> common ++ ~w(request_id status metadata scope revision)
        "summary" -> common
        _ -> []
      end

    valid =
      allowed != [] and MapSet.new(Map.keys(attrs)) == MapSet.new(allowed) and
        attrs["operation"] == "workflow_budget" and attrs["schema"] == @schema and
        is_integer(attrs["limit"]) and attrs["limit"] in 0..100_000 and
        bounded?(attrs["job_id"], 256) and bounded?(attrs["run_id"], 256) and
        valid_name?(attrs["name"])

    valid =
      valid and
        case attrs["action"] do
          "start" ->
            Enum.all?(@identity_fields, &bounded?(attrs[&1], 4096, true)) and
              valid_id?(attrs["request_id"]) and valid_metadata?(attrs["metadata"])

          "complete" ->
            valid_id?(attrs["request_id"]) and bounded?(attrs["status"], 128) and
              valid_metadata?(attrs["metadata"]) and
              bounded?(attrs["scope"], 4096) and bounded?(attrs["revision"], 4096)

          "summary" ->
            true

          _ ->
            false
        end

    if valid, do: :ok, else: {:error, "invalid workflow budget request"}
  end

  defp validate_request(_), do: {:error, "workflow budget request must be an object"}

  defp validate_state(state, _run_id) when state == %{}, do: :ok
  defp validate_state(%{"run_id" => run_id, "pools" => pools}, run_id) when is_map(pools), do: :ok
  defp validate_state(_, _), do: {:error, "workflow budget state belongs to a different run"}

  defp validate_pool(%{"limit" => limit, "used" => used, "actions" => actions} = pool, limit)
       when is_integer(used) and is_map(actions) do
    records =
      actions
      |> Map.values()
      |> Enum.sort_by(fn record ->
        if is_map(record) and is_map(record["action"]),
          do: record["action"]["action_index"],
          else: 0
      end)

    valid =
      MapSet.new(Map.keys(pool)) == MapSet.new(~w(limit used actions)) and
        map_size(actions) <= @max_records and used == min(map_size(actions), limit) and
        Enum.all?(Enum.with_index(records, 1), fn {record, index} ->
          valid_record?(record, index, limit, actions)
        end)

    if valid and byte_size(Jason.encode!(pool)) <= @max_journal_bytes,
      do: :ok,
      else: {:error, "workflow budget accounting is invalid"}
  end

  defp validate_pool(_, _), do: {:error, "workflow budget accounting is invalid"}

  defp valid_record?(%{"request" => request, "action" => action} = record, index, limit, actions)
       when is_map(request) and is_map(action) do
    id = action["reservation_id"]

    valid =
      valid_id?(id) and Map.get(actions, id) == record and
        MapSet.new(Map.keys(request)) == MapSet.new(@identity_fields ++ ["metadata"]) and
        Enum.all?(@identity_fields, &bounded?(request[&1], 4096, true)) and
        valid_metadata?(request["metadata"]) and action["action_index"] == index and
        action["cost"] == if(index <= limit, do: 1, else: 0) and
        action["budget"] == limit and action["used"] == min(index, limit) and
        action["remaining"] == max(0, limit - index) and bounded?(action["recorded_at"], 128) and
        Enum.all?(@identity_fields, &(action[&1] == request[&1]))

    valid and
      case record["completion"] do
        nil ->
          MapSet.new(Map.keys(record)) == MapSet.new(~w(request action)) and
            action["status"] == if(action["cost"] == 1, do: "started", else: "budget_exhausted") and
            action["metadata"] == request["metadata"]

        completion when is_map(completion) ->
          MapSet.new(Map.keys(record)) == MapSet.new(~w(request action completion)) and
            MapSet.new(Map.keys(completion)) == MapSet.new(~w(status metadata)) and
            action["cost"] == 1 and bounded?(completion["status"], 128) and
            valid_metadata?(completion["metadata"]) and action["status"] == completion["status"] and
            action["metadata"] == Map.merge(request["metadata"], completion["metadata"]) and
            bounded?(action["completed_at"], 128)

        _ ->
          false
      end
  end

  defp valid_record?(_, _, _, _), do: false

  defp bounded_pool(pool, response) do
    if byte_size(Jason.encode!(pool)) <= @max_journal_bytes,
      do: {:ok, response, pool},
      else: {:error, "workflow budget audit byte capacity exceeded"}
  end

  defp persist_if_changed(state, state, _persist), do: :ok

  defp persist_if_changed(_state, next, persist) do
    case persist.(next) do
      {:ok, _} -> :ok
      :ok -> :ok
      _ -> {:error, "workflow budget reservation could not be durably committed"}
    end
  end

  defp valid_name?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]{0,63}$/, value)

  defp valid_id?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)

  defp bounded?(value, max, empty \\ false),
    do: is_binary(value) and byte_size(value) <= max and (empty or value != "")

  defp valid_metadata?(value) when is_map(value) do
    case Jason.encode(value) do
      {:ok, bytes} -> byte_size(bytes) <= 16384
      _ -> false
    end
  end

  defp valid_metadata?(_), do: false
end
