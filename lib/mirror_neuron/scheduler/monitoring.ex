defmodule MirrorNeuron.Scheduler.Monitoring do
  @moduledoc "Compact scheduler status projection for runtime monitoring."

  def scheduler_summary(%{"scheduler" => scheduler}) when is_map(scheduler) do
    %{
      "status" => Map.get(scheduler, "status"),
      "job_type" => Map.get(scheduler, "job_type"),
      "strategy" => Map.get(scheduler, "strategy"),
      "mode" => Map.get(scheduler, "mode"),
      "placement_count" => Map.get(scheduler, "placement_count", 0),
      "nodes" =>
        scheduler
        |> Map.get("placements", [])
        |> Enum.map(&Map.get(&1, "node"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  def scheduler_summary(_job), do: nil
end
