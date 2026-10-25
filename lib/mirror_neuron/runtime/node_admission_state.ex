defmodule MirrorNeuron.Runtime.NodeAdmissionState do
  @moduledoc "Durable, fenced resource reservations and bounded-backfill transitions."
  alias MirrorNeuron.Runtime.ResourceAllocation

  def new do
    %{
      "schema_version" => 2,
      "version" => 0,
      "generation" => 0,
      "reservations" => %{},
      "queue" => [],
      "deferred" => [],
      "requests" => %{},
      "legacy" => []
    }
  end

  # Existing whole-PC claims remain exclusive until their original cleanup.
  def upgrade(%{"schema_version" => 2} = state), do: normalize_empty_lists(state)

  def upgrade(state) do
    reservations =
      case state["holder"] do
        %{"run_id" => id} = holder ->
          %{
            id =>
              holder
              |> Map.put("allocation", %{"mode" => "exclusive_node"})
              |> Map.put("committed", true)
          }

        _ ->
          %{}
      end

    new()
    |> Map.merge(Map.take(state, ~w(version generation queue deferred requests legacy)))
    |> Map.put("reservations", reservations)
    |> normalize_empty_lists()
  end

  defp normalize_empty_lists(state) do
    Enum.reduce(~w(queue deferred legacy), state, fn key, acc ->
      Map.update(acc, key, [], fn
        value when is_map(value) and map_size(value) == 0 -> []
        value -> value
      end)
    end)
  end

  def transition(state, operation, attrs), do: apply_transition(upgrade(state), operation, attrs)

  defp apply_transition(state, "submit", entry) do
    id = entry["run_id"]

    eligibility =
      ResourceAllocation.allocate(entry["request"] || exclusive(), capacity(entry), [],
        live: false
      )

    cond do
      Map.has_key?(state["reservations"], id) or
          Enum.any?(state["queue"] ++ state["deferred"], &(&1["run_id"] == id)) ->
        {:ok, state, receipt(state, id)}

      match?({:error, _}, eligibility) ->
        {:error, {:resource_requirement_unmet, elem(eligibility, 1)}}

      length(state["queue"]) + length(state["deferred"]) >= 1000 ->
        {:error, :node_queue_full}

      true ->
        capacity = capacity(entry)
        next = promote(state, capacity)

        entry =
          Map.put_new(entry, "request", exclusive())
          |> Map.put_new("bypasses", 0)
          |> Map.drop(["capacity"])

        next = promote(%{next | "queue" => next["queue"] ++ [entry]}, capacity)
        {:ok, next, receipt(next, id)}
    end
  end

  defp apply_transition(state, "submit_now", entry) do
    case apply_transition(state, "submit", entry) do
      {:ok, next, %{"state" => "preparing"} = receipt} -> {:ok, next, receipt}
      {:ok, _next, receipt} -> {:error, {:admission_blocked, Map.put(receipt, "accepted", false)}}
      error -> error
    end
  end

  defp apply_transition(state, "promote", attrs) do
    next = promote(state, capacity(attrs))
    {:ok, next, Map.values(next["reservations"])}
  end

  defp apply_transition(state, "defer", %{"run_id" => id, "not_before" => at}) do
    entry =
      state["reservations"][id] ||
        Enum.find(state["queue"] ++ state["deferred"], &(&1["run_id"] == id))

    cond do
      entry == nil ->
        {:error, :run_not_queued}

      active_requests?(state, id) ->
        {:error, :node_requests_active}

      true ->
        next =
          state
          |> Map.put("reservations", Map.delete(state["reservations"], id))
          |> Map.put("queue", Enum.reject(state["queue"], &(&1["run_id"] == id)))
          |> Map.put(
            "deferred",
            Enum.reject(state["deferred"], &(&1["run_id"] == id)) ++
              [entry |> Map.drop(["allocation", "generation"]) |> Map.put("not_before", at)]
          )

        {:ok, next, receipt(next, id)}
    end
  end

  defp apply_transition(state, "cancel", %{"run_id" => id} = attrs) do
    cond do
      Map.has_key?(state["reservations"], id) and attrs["before_start"] != true ->
        {:error, :run_already_admitted}

      active_requests?(state, id) ->
        {:error, :node_requests_active}

      true ->
        next =
          state
          |> Map.put("reservations", Map.delete(state["reservations"], id))
          |> Map.put("queue", Enum.reject(state["queue"], &(&1["run_id"] == id)))
          |> Map.put("deferred", Enum.reject(state["deferred"], &(&1["run_id"] == id)))

        {:ok, next, %{"status" => "cancelled"}}
    end
  end

  defp apply_transition(state, "release", %{"run_id" => id, "generation" => generation}) do
    held = state["reservations"][id]

    cond do
      held == nil and map_size(state["reservations"]) == 0 ->
        {:ok, state, %{"status" => "released"}}

      held == nil ->
        {:error, :stale_node_reservation}

      held["generation"] != generation ->
        {:error, :stale_node_reservation}

      active_requests?(state, id) ->
        {:error, :node_requests_active}

      true ->
        {:ok, %{state | "reservations" => Map.delete(state["reservations"], id)},
         %{"status" => "released"}}
    end
  end

  defp apply_transition(state, "cleanup_pending", %{"run_id" => id, "generation" => generation}) do
    case state["reservations"][id] do
      %{"generation" => ^generation} = held ->
        {:ok, put_in(state, ["reservations", id], Map.put(held, "cleanup_state", "pending")),
         %{"status" => "cleanup_pending"}}

      _ ->
        {:error, :stale_node_reservation}
    end
  end

  defp apply_transition(state, "commit", %{"run_id" => id, "generation" => generation}) do
    case state["reservations"][id] do
      %{"generation" => ^generation} = held ->
        {:ok, put_in(state, ["reservations", id], Map.put(held, "committed", true)),
         %{"status" => "committed"}}

      _ ->
        {:error, :stale_node_reservation}
    end
  end

  defp apply_transition(state, "request_acquire", %{"run_id" => id, "token" => token} = attrs) do
    held = state["reservations"][id]

    cond do
      Map.has_key?(state["requests"], token) ->
        if state["requests"][token] == id,
          do: {:ok, state, %{"status" => "acquired", "token" => token}},
          else: {:error, :stale_node_reservation}

      map_size(state["requests"]) >= 4096 ->
        {:error, :node_requests_full}

      held != nil and held["generation"] != attrs["generation"] ->
        {:error, :stale_node_reservation}

      held != nil or id in state["legacy"] ->
        {:ok, put_in(state, ["requests", token], id), %{"status" => "acquired", "token" => token}}

      id == "" ->
        entry = %{
          "run_id" => "request_" <> token,
          "request" => attrs["request"] || exclusive(),
          "capacity" => capacity(attrs)
        }

        case apply_transition(state, "submit_now", entry) do
          {:ok, next, _} ->
            {:ok, put_in(next, ["requests", token], ""),
             %{"status" => "acquired", "token" => token}}

          _ ->
            {:error, :node_reserved}
        end

      true ->
        {:error, :node_reserved}
    end
  end

  defp apply_transition(state, "request_release", %{"token" => token}) do
    next = %{
      state
      | "requests" => Map.delete(state["requests"], token),
        "reservations" => Map.delete(state["reservations"], "request_" <> token)
    }

    {:ok, next, %{"status" => "released"}}
  end

  defp apply_transition(state, "import", %{"runs" => runs}) do
    known =
      Map.keys(state["reservations"]) ++
        Enum.map(state["queue"] ++ state["deferred"], & &1["run_id"])

    {:ok, %{state | "legacy" => Enum.uniq(state["legacy"] ++ Enum.reject(runs, &(&1 in known)))},
     %{}}
  end

  defp apply_transition(state, "release_legacy", %{"run_id" => id}),
    do: {:ok, %{state | "legacy" => List.delete(state["legacy"], id)}, %{}}

  defp apply_transition(_state, _operation, _attrs), do: {:error, :invalid_node_admission_command}

  def receipt(state, id) do
    state = upgrade(state)

    case state["reservations"][id] do
      %{} = held ->
        held
        |> Map.drop(["request", "bypasses"])
        |> Map.put("state", "preparing")
        |> Map.put("queue_id", "queue_" <> id)

      _ ->
        index = Enum.find_index(state["queue"], &(&1["run_id"] == id))

        entry =
          if index != nil,
            do: Enum.at(state["queue"], index),
            else: Enum.find(state["deferred"], &(&1["run_id"] == id))

        if entry do
          blocker =
            state["reservations"]
            |> Map.values()
            |> Enum.sort_by(&(&1["generation"] || 0))
            |> List.first()

          blocker =
            blocker ||
              if(state["legacy"] != [],
                do: %{"run_id" => hd(state["legacy"])},
                else: %{"job_name" => "resource preparation or inference"}
              )

          %{
            "state" => "queued",
            "queue_id" => "queue_" <> id,
            "position" => if(index != nil, do: index + 1),
            "not_before" => entry["not_before"],
            "blockers" => entry["blockers"] || [],
            "blocked_by" =>
              if(String.starts_with?(blocker["run_id"] || "", "request_"),
                do: %{"job_name" => "resource preparation or inference"},
                else: Map.drop(blocker, ["request", "allocation"])
              )
          }
        else
          %{"state" => "unreserved", "run_id" => id}
        end
    end
  end

  def allocations(state),
    do: Enum.map(Map.values(upgrade(state)["reservations"]), & &1["allocation"])

  defp promote(state, capacity) do
    now = DateTime.utc_now()

    {due, later} =
      Enum.split_with(state["deferred"], fn entry ->
        case DateTime.from_iso8601(entry["not_before"]) do
          {:ok, at, _} -> DateTime.compare(at, now) != :gt
          _ -> false
        end
      end)

    state = %{
      state
      | "deferred" => later,
        "queue" => state["queue"] ++ Enum.sort_by(due, & &1["not_before"])
    }

    {next, waiting} =
      Enum.reduce(state["queue"], {%{state | "queue" => []}, []}, fn entry, {acc, waiting} ->
        request = entry["request"] || exclusive()

        allocations =
          allocations(acc) ++ protected_allocations(waiting, capacity) ++ legacy_allocations(acc)

        case ResourceAllocation.allocate(request, capacity, allocations) do
          {:ok, allocation} ->
            generation = acc["generation"] + 1

            holder =
              entry
              |> Map.drop(["blockers"])
              |> Map.merge(%{
                "generation" => generation,
                "allocation" => allocation,
                "committed" => false
              })

            acc = %{
              acc
              | "generation" => generation,
                "reservations" => Map.put(acc["reservations"], entry["run_id"], holder)
            }

            {acc, Enum.map(waiting, &Map.update(&1, "bypasses", 1, fn n -> n + 1 end))}

          {:error, blockers} ->
            {acc, waiting ++ [Map.put(entry, "blockers", blockers)]}
        end
      end)

    %{next | "queue" => waiting}
  end

  defp protected_allocations(entries, capacity) do
    entries
    |> Enum.filter(&((&1["bypasses"] || 0) >= 3))
    |> Enum.flat_map(fn entry ->
      case ResourceAllocation.allocate(entry["request"] || exclusive(), capacity, [], live: false) do
        {:ok, allocation} -> [allocation]
        _ -> []
      end
    end)
  end

  defp legacy_allocations(state) do
    unowned =
      Enum.any?(state["requests"], fn {token, run} ->
        run == "" and not Map.has_key?(state["reservations"], "request_" <> token)
      end)

    if state["legacy"] != [] or unowned, do: [%{"mode" => "exclusive_node"}], else: []
  end

  defp active_requests?(state, id),
    do: Enum.any?(state["requests"], fn {_token, run} -> run == id end)

  defp capacity(attrs),
    do:
      attrs["capacity"] ||
        %{
          "resources" => %{"cpu_cores" => 0, "memory_mb" => 0, "disk_mb" => 0},
          "available" => %{},
          "devices" => [],
          "gpu_ratio" => 1,
          "managed_usage" => %{}
        }

  defp exclusive, do: %{"mode" => "exclusive_node", "devices" => []}
end
