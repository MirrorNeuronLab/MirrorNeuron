defmodule MirrorNeuron.Grpc.RunPlacement do
  @moduledoc false

  alias MirrorNeuron.Runtime.{NodeAdmission, NodeAdmissionState}

  def read(record, run_id) do
    owner = record["owner_node"] || NodeAdmission.node_name()
    placement = %{"owner_node" => owner, "reservation" => %{"state" => "unavailable"}}

    with true <- owner == NodeAdmission.node_name(),
         {:ok, state} <- NodeAdmission.snapshot(),
         false <- run_id in state["legacy"] do
      receipt = state |> NodeAdmissionState.receipt(run_id) |> NodeAdmission.decorate()

      placement
      |> Map.put("node_label", receipt["node_label"])
      |> Map.put("reservation", reservation(receipt))
    else
      _ -> placement
    end
  end

  defp reservation(%{"state" => "preparing", "allocation" => allocation})
       when is_map(allocation) do
    resources = allocation["resources"] || %{}
    devices = allocation["devices"]
    gpus = if is_list(devices), do: Enum.filter(devices, &(&1["kind"] == "gpu"))

    %{
      "state" => "reserved",
      "mode" => allocation["mode"],
      "cpu_cores" => number(resources["cpu_cores"]),
      "memory_mb" => number(resources["memory_mb"]),
      "disk_mb" => number(resources["disk_mb"]),
      "gpu_count" => if(gpus, do: length(gpus)),
      "gpu_memory_mb" => gpu_memory(gpus)
    }
  end

  defp reservation(%{"state" => state}) when state in ["queued", "unreserved"],
    do: %{"state" => state}

  defp reservation(_), do: %{"state" => "unavailable"}

  defp gpu_memory(nil), do: nil

  defp gpu_memory(devices) do
    values = Enum.map(devices, &number(&1["reservation_memory_mb"] || &1["memory_total_mb"]))
    if Enum.all?(values, &is_number/1), do: Enum.sum(values)
  end

  defp number(value) when is_number(value) and value >= 0, do: value
  defp number(_), do: nil
end
