defmodule MirrorNeuron.Runtime.NodeAdmissionState do
  @moduledoc "Pure, versioned state transitions for one PC's exclusive run admission."

  def new,
    do: %{
      "version" => 0,
      "generation" => 0,
      "holder" => nil,
      "queue" => [],
      "deferred" => [],
      "requests" => %{},
      "legacy" => []
    }

  def transition(state, "submit", entry) do
    id = entry["run_id"]

    cond do
      get_in(state, ["holder", "run_id"]) == id ->
        {:ok, state, receipt(state, id)}

      Enum.any?(state["queue"], &(&1["run_id"] == id)) ->
        {:ok, state, receipt(state, id)}

      Enum.any?(Map.get(state, "deferred", []), &(&1["run_id"] == id)) ->
        {:ok, state, receipt(state, id)}

      length(state["queue"]) + length(Map.get(state, "deferred", [])) >= 1000 ->
        {:error, :node_queue_full}

      true ->
        # Materialize overdue scheduled starts before this new arrival, even
        # when a periodic dispatcher tick was missed.
        state = promote(state)
        next = %{state | "queue" => state["queue"] ++ [entry]}
        next = promote(next)
        {:ok, next, receipt(next, id)}
    end
  end

  def transition(state, "promote", _attrs) do
    next = promote(state)
    {:ok, next, next["holder"]}
  end

  def transition(state, "defer", %{"run_id" => id, "not_before" => at}) do
    entry =
      if get_in(state, ["holder", "run_id"]) == id,
        do: state["holder"],
        else: Enum.find(state["queue"] ++ Map.get(state, "deferred", []), &(&1["run_id"] == id))

    cond do
      entry == nil ->
        {:error, :run_not_queued}

      Enum.any?(state["requests"], fn {_token, run} -> run == id end) ->
        {:error, :node_requests_active}

      true ->
        next =
          state
          |> Map.put(
            "holder",
            if(get_in(state, ["holder", "run_id"]) == id, do: nil, else: state["holder"])
          )
          |> Map.put("queue", Enum.reject(state["queue"], &(&1["run_id"] == id)))
          |> Map.put(
            "deferred",
            Enum.reject(Map.get(state, "deferred", []), &(&1["run_id"] == id)) ++
              [Map.put(entry, "not_before", at)]
          )

        {:ok, next, receipt(next, id)}
    end
  end

  def transition(state, "cancel", %{"run_id" => id, "before_start" => true}) do
    if get_in(state, ["holder", "run_id"]) == id do
      if Enum.any?(state["requests"], fn {_token, run} -> run == id end),
        do: {:error, :node_requests_active},
        else: {:ok, %{state | "holder" => nil}, %{"status" => "cancelled"}}
    else
      transition(state, "cancel", %{"run_id" => id})
    end
  end

  def transition(state, "cancel", %{"run_id" => id}) do
    if get_in(state, ["holder", "run_id"]) == id do
      {:error, :run_already_admitted}
    else
      next =
        state
        |> Map.put("queue", Enum.reject(state["queue"], &(&1["run_id"] == id)))
        |> Map.put("deferred", Enum.reject(Map.get(state, "deferred", []), &(&1["run_id"] == id)))

      {:ok, next, %{"status" => "cancelled"}}
    end
  end

  def transition(state, "release", %{"run_id" => id, "generation" => generation}) do
    holder = state["holder"]

    cond do
      holder == nil ->
        {:ok, state, %{"status" => "released"}}

      holder["run_id"] != id or holder["generation"] != generation ->
        {:error, :stale_node_reservation}

      Enum.any?(state["requests"], fn {_token, run} -> run == id end) ->
        {:error, :node_requests_active}

      true ->
        {:ok, %{state | "holder" => nil}, %{"status" => "released"}}
    end
  end

  def transition(state, "request_acquire", %{"run_id" => id, "token" => token} = attrs) do
    holder = get_in(state, ["holder", "run_id"])

    if holder == id and id != "" and
         attrs["generation"] != get_in(state, ["holder", "generation"]) do
      {:error, :stale_node_reservation}
    else
      if (id != "" and (holder == id or id in state["legacy"])) or
           (holder == nil and state["queue"] == [] and state["legacy"] == [] and id == "") do
        if map_size(state["requests"]) >= 4096,
          do: {:error, :node_requests_full},
          else:
            {:ok, put_in(state, ["requests", token], id),
             %{"status" => "acquired", "token" => token}}
      else
        {:error, :node_reserved}
      end
    end
  end

  def transition(state, "request_release", %{"token" => token}) do
    {:ok, %{state | "requests" => Map.delete(state["requests"], token)},
     %{"status" => "released"}}
  end

  def transition(state, "import", %{"runs" => runs}) do
    held = get_in(state, ["holder", "run_id"])
    queued = Enum.map(state["queue"], & &1["run_id"])
    legacy = Enum.uniq(state["legacy"] ++ Enum.reject(runs, &(&1 == held or &1 in queued)))
    {:ok, %{state | "legacy" => legacy}, %{}}
  end

  def transition(state, "release_legacy", %{"run_id" => id}) do
    {:ok, %{state | "legacy" => List.delete(state["legacy"], id)}, %{}}
  end

  def transition(_state, _operation, _attrs), do: {:error, :invalid_node_admission_command}

  def receipt(state, id) do
    if get_in(state, ["holder", "run_id"]) == id do
      state["holder"] |> Map.put("state", "preparing") |> Map.put("queue_id", "queue_" <> id)
    else
      index = Enum.find_index(state["queue"], &(&1["run_id"] == id))
      deferred = Enum.find(Map.get(state, "deferred", []), &(&1["run_id"] == id))

      if index != nil or deferred != nil do
        %{
          "state" => "queued",
          "queue_id" => "queue_" <> id,
          "not_before" => deferred && deferred["not_before"],
          "position" => if(index, do: index + 1, else: nil),
          "blocked_by" =>
            state["holder"] ||
              if(state["legacy"] != [],
                do: %{"run_id" => List.first(state["legacy"])},
                else: %{"job_name" => "resource preparation or inference"}
              )
        }
      else
        %{"state" => "unreserved", "run_id" => id}
      end
    end
  end

  defp promote(state) do
    now = DateTime.utc_now()

    {due, later} =
      Enum.split_with(Map.get(state, "deferred", []), fn entry ->
        case DateTime.from_iso8601(entry["not_before"]) do
          {:ok, at, _} -> DateTime.compare(at, now) != :gt
          _ -> false
        end
      end)

    state
    |> Map.put("deferred", later)
    |> Map.put("queue", state["queue"] ++ Enum.sort_by(due, & &1["not_before"]))
    |> claim()
  end

  defp claim(%{"holder" => nil, "queue" => [entry | rest], "legacy" => []} = state) do
    if map_size(state["requests"]) == 0 do
      generation = state["generation"] + 1

      %{
        state
        | "holder" => Map.put(entry, "generation", generation),
          "queue" => rest,
          "generation" => generation
      }
    else
      state
    end
  end

  defp claim(state), do: state
end
