defmodule MirrorNeuron.Scheduler.Admission.Inspection do
  @moduledoc "Read-only availability checks and user-facing admission receipts."

  alias MirrorNeuron.Cluster.Hardware

  alias MirrorNeuron.Runtime.{
    AdmissionLedger,
    NodeAdmission,
    NodeAdmissionState,
    ResourceAllocation
  }

  import AdmissionLedger, only: [store: 0]
  import NodeAdmission, only: [node_name: 0, pin: 1, snapshot: 0]
  @terminal ~w(completed failed cancelled)

  def check(manifest, run_id \\ nil) do
    with {:ok, manifest} <- MirrorNeuron.Manifest.load(manifest),
         {:ok, state} <- snapshot(),
         {:ok, capacity} <- AdmissionLedger.capacity(),
         {:ok, request} <- ResourceAllocation.request(manifest) do
      retained =
        is_binary(run_id) and Map.has_key?(state["reservations"], run_id) and
          match?({:ok, %{"status" => "paused"}}, store().fetch_job(run_id))

      state =
        if run_id,
          do: %{state | "reservations" => Map.delete(state["reservations"], run_id)},
          else: state

      allocations = NodeAdmissionState.allocations(state)

      result =
        if retained and capacity["telemetry_current"] != false,
          do: %{"status" => "runnable_now", "blockers" => []},
          else: ResourceAllocation.check(request, capacity, allocations)

      result =
        if result["status"] == "runnable_now" and not retained do
          case NodeAdmissionState.transition(state, "submit_now", %{
                 "run_id" => "admission_check",
                 "request" => request,
                 "capacity" => capacity
               }) do
            {:ok, _, _} ->
              result

            _ ->
              Map.merge(result, %{
                "status" => "runnable_later",
                "blockers" => [
                  %{
                    "code" => "MN_RESOURCE_EXHAUSTED",
                    "resource" => "queue_priority",
                    "node_index" => 1
                  }
                ]
              })
          end
        else
          result
        end

      result =
        if result["status"] in ["runnable_now", "runnable_later"] do
          case MirrorNeuron.Scheduler.plan(pin(manifest), jobs: [], exclusive_run: true) do
            {:ok, _} ->
              result

            {:error, _reason} ->
              %{
                "status" => "not_runnable",
                "blockers" => [
                  %{
                    "code" => "MN_PLACEMENT_UNSATISFIED",
                    "resource" => "placement",
                    "node_index" => 1
                  }
                ]
              }
          end
        else
          result
        end

      {:ok,
       result
       |> Map.drop(["allocation"])
       |> Map.put("owner_node", node_name())
       |> Map.put("node_label", node_label())
       |> Map.put("observed_at", MirrorNeuron.Runtime.timestamp())}
    end
  end

  defp node_label do
    hardware = Hardware.info()
    get_in(hardware, [:platform, :display_name]) || node_name()
  end

  def decorate(receipt) do
    hardware = Hardware.info()
    label = get_in(hardware, [:platform, :display_name]) || node_name()
    blocker = receipt["blocked_by"] || %{}

    blocking_job =
      case blocker["run_id"] && store().fetch_job(blocker["run_id"]) do
        {:ok, job} -> job
        _ -> %{}
      end

    status = blocking_job["status"] || blocker["status"]

    suffix =
      cond do
        status == "paused" -> " (paused)"
        status in @terminal -> " (cleanup in progress)"
        true -> ""
      end

    blocked = (blocker["job_name"] || blocking_job["job_name"] || "the current run") <> suffix

    automatic =
      if is_integer(receipt["position"]) and receipt["position"] > 1,
        do: "It will start automatically when earlier runs finish.",
        else: "It will start automatically when the current run finishes."

    receipt =
      if map_size(blocker) > 0,
        do:
          Map.put(
            receipt,
            "blocked_by",
            Map.merge(blocker, %{"job_name" => blocked, "status" => status})
          ),
        else: receipt

    receipt
    |> Map.put("owner_node", node_name())
    |> Map.put("node_label", label)
    |> Map.put(
      "message",
      if(receipt["state"] == "queued",
        do:
          if(receipt["not_before"],
            do:
              "Scheduled on #{label} for #{receipt["not_before"]}. It will wait automatically if the PC is busy.",
            else: "Queued on #{label} behind #{blocked}. #{automatic}"
          ),
        else:
          if(receipt["state"] == "preparing",
            do: "Resources reserved on #{label}.",
            else: "No active reservation for this run on #{label}."
          )
      )
    )
  end
end
