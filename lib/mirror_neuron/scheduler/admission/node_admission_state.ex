defmodule MirrorNeuron.Runtime.NodeAdmissionState do
  @moduledoc "Durable, fenced resource reservations and bounded-backfill transitions."
  alias MirrorNeuron.Runtime.{NativeRequestClaim, ResourceAllocation}

  def new do
    %{
      "schema_version" => 3,
      "version" => 0,
      "generation" => 0,
      "reservations" => %{},
      "queue" => [],
      "deferred" => [],
      "requests" => %{}
    }
  end

  def decode(
        %{
          "schema_version" => 3,
          "reservations" => reservations,
          "requests" => requests,
          "queue" => _,
          "deferred" => _,
          "version" => version,
          "generation" => generation
        } = state
      )
      when is_map(reservations) and is_map(requests) and is_integer(version) and
             is_integer(generation) do
    state = normalize_empty_lists(state)

    if is_list(state["queue"]) and is_list(state["deferred"]) do
      {:ok, state}
    else
      {:error, :unsupported_node_admission_state}
    end
  end

  def decode(_), do: {:error, :unsupported_node_admission_state}

  defp normalize_empty_lists(state) do
    Enum.reduce(~w(queue deferred), state, fn key, acc ->
      Map.update(acc, key, [], fn
        value when is_map(value) and map_size(value) == 0 -> []
        value -> value
      end)
    end)
  end

  def transition(state, operation, attrs) do
    with {:ok, state} <- decode(state), do: apply_transition(state, operation, attrs)
  end

  defp apply_transition(state, "submit", entry) do
    id = entry["run_id"]

    eligibility =
      ResourceAllocation.allocate(entry["request"] || exclusive(), capacity(entry), [],
        live: false
      )

    cond do
      NativeRequestClaim.native?(state["reservations"][id]) and
          not NativeRequestClaim.native?(entry) ->
        {:error, :node_reserved}

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

      NativeRequestClaim.native?(held) or held["generation"] != generation ->
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
    existing = Map.fetch(state["requests"], token)
    held = state["reservations"][id]

    cond do
      existing != :error and existing != {:ok, id} ->
        {:error, :stale_node_reservation}

      existing == :error and map_size(state["requests"]) >= 4096 ->
        {:error, :node_requests_full}

      id == "" ->
        acquire_native(state, token, attrs, existing)

      NativeRequestClaim.native?(held) or
          (held != nil and held["generation"] != attrs["generation"]) ->
        {:error, :stale_node_reservation}

      held != nil ->
        with {:ok, allocation} <- default_model_allocation(state, held, attrs) do
          next =
            state
            |> put_in(["reservations", id, "allocation"], allocation)
            |> put_in(["requests", token], id)

          {:ok, next, acquired(token, allocation)}
        end

      true ->
        {:error, :node_reserved}
    end
  end

  defp apply_transition(state, "request_release", %{"token" => token} = attrs) do
    native_id = NativeRequestClaim.id(token)

    case Map.fetch(state["requests"], token) do
      :error ->
        {:ok, state, %{"status" => "released"}}

      {:ok, owner} ->
        cond do
          attrs["run_id"] not in [nil, "", owner] ->
            {:error, :stale_node_reservation}

          true ->
            reservations =
              if owner == "" and NativeRequestClaim.native?(state["reservations"][native_id]),
                do: Map.delete(state["reservations"], native_id),
                else: state["reservations"]

            {:ok,
             %{
               state
               | "requests" => Map.delete(state["requests"], token),
                 "reservations" => reservations
             }, %{"status" => "released"}}
        end
    end
  end

  defp apply_transition(_state, _operation, _attrs), do: {:error, :invalid_node_admission_command}

  defp acquire_native(state, token, attrs, {:ok, ""}) do
    held = state["reservations"][NativeRequestClaim.id(token)]

    if NativeRequestClaim.native?(held) and
         (attrs["generation"] == nil or attrs["generation"] == held["generation"]),
       do: {:ok, state, acquired(token, held["allocation"])},
       else: {:error, :stale_node_reservation}
  end

  defp acquire_native(state, token, attrs, :error) do
    entry = NativeRequestClaim.entry(token, attrs["request"] || exclusive(), capacity(attrs))

    with nil <- state["reservations"][entry["run_id"]],
         {:ok, next, %{"allocation" => allocation}} <-
           apply_transition(state, "submit_now", entry) do
      {:ok, put_in(next, ["requests", token], ""), acquired(token, allocation)}
    else
      %{} -> {:error, :stale_node_reservation}
      _ -> {:error, :node_reserved}
    end
  end

  # The native model service resolves the concrete recipe. Pin its charge to
  # the parent Run so request release and retries cannot free it prematurely.
  defp default_model_allocation(
         state,
         %{"request" => %{"shared_default_model" => true}} = held,
         %{
           "request" =>
             %{"devices" => [%{"models" => [%{"key" => "managed:" <> _ = key} = weight]}]} = model
         } = attrs
       ) do
    allocation = held["allocation"]

    slot =
      if weight["purpose"] == "embedding", do: "embedding_model_key", else: "default_model_key"

    pinned = allocation["default_model_key"] || allocation["embedding_model_key"]

    cond do
      allocation[slot] == key ->
        {:ok, allocation}

      allocation[slot] != nil ->
        {:error, :default_model_changed}

      allocation["devices"] != [] and is_nil(pinned) ->
        {:error, :invalid_resource_allocation}

      Map.has_key?(state["requests"], attrs["token"]) ->
        {:error, :stale_node_reservation}

      true ->
        bind_managed_model(state, allocation, capacity(attrs), model, slot, key)
    end
  end

  defp default_model_allocation(_, held, _), do: {:ok, held["allocation"]}

  defp bind_managed_model(state, allocation, cap, model, slot, key) do
    previous = List.first(allocation["devices"])
    # Older receipts contain only the primary model and its original reservation.
    previous_mb =
      cond do
        mb = allocation["managed_model_memory_mb"] -> mb
        previous -> previous["reservation_memory_mb"]
        allocation["default_model_key"] -> allocation["resources"]["memory_mb"]
        true -> 0
      end

    total_mb = previous_mb + model["memory_mb"]
    cpu? = cap["devices"] == []
    [device] = model["devices"]
    device = if previous, do: Map.put(device, "ids", [previous["id"]]), else: device

    request =
      if cpu?,
        do: %{model | "devices" => [], "memory_mb" => total_mb},
        else: %{model | "devices" => [device], "memory_mb" => 1}

    # Include this Run's existing claim. Allocate only the new model against
    # remaining capacity, then retain both charges through terminal cleanup.
    reserved = Enum.map(state["reservations"], fn {_, run} -> run["allocation"] end)

    with true <- previous_mb == 0 or cpu? == is_nil(previous),
         {:ok, bound} <- ResourceAllocation.allocate(request, cap, reserved) do
      resources =
        Map.update!(allocation["resources"], "memory_mb", &max(&1, request["memory_mb"]))

      devices = merge_model_devices(previous, bound["devices"])

      {:ok,
       Map.merge(allocation, %{
         slot => key,
         "managed_model_memory_mb" => total_mb,
         "devices" => devices,
         "resources" => resources
       })}
    else
      _ -> {:error, :node_reserved}
    end
  end

  defp merge_model_devices(nil, devices), do: devices

  defp merge_model_devices(previous, [device]) do
    [
      device
      |> Map.update!("models", &(previous["models"] ++ &1))
      |> Map.update!("reservation_memory_mb", &(previous["reservation_memory_mb"] + &1))
      |> Map.update!("incremental_memory_mb", &((previous["incremental_memory_mb"] || 0) + &1))
    ]
  end

  defp acquired(token, allocation),
    do: %{"status" => "acquired", "token" => token, "allocation" => allocation}

  def report(state) do
    reservations =
      Map.new(state["reservations"], fn {id, entry} ->
        NativeRequestClaim.report_entry(id, entry)
      end)

    Map.take(state, ~w(queue generation)) |> Map.put("reservations", reservations)
  end

  def receipt(state, id) do
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

          blocker = blocker || %{"job_name" => "resource preparation or inference"}

          %{
            "state" => "queued",
            "queue_id" => "queue_" <> id,
            "position" => if(index != nil, do: index + 1),
            "not_before" => entry["not_before"],
            "blockers" => entry["blockers"] || [],
            "blocked_by" =>
              if(NativeRequestClaim.native?(blocker),
                do: %{"job_name" => "resource preparation or inference"},
                else: Map.drop(blocker, ["request", "allocation"])
              )
          }
        else
          %{"state" => "unreserved", "run_id" => id}
        end
    end
  end

  def allocations(state), do: reservation_allocations(state)

  defp reservation_allocations(state),
    do: Enum.map(Map.values(state["reservations"]), & &1["allocation"])

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
          reservation_allocations(acc) ++
            protected_allocations(waiting, capacity)

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
