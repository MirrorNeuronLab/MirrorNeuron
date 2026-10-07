defmodule MirrorNeuron.Scheduler.AdmissionProblem do
  @moduledoc false

  alias MirrorNeuron.HardwareRequirements
  alias MirrorNeuron.ResourceSpec

  # The SDK owns messages, hints, and the numeric error catalog. Core supplies
  # measured blockers without changing scheduler admission or exposing config.
  def encode(blockers) do
    "\nmn_admission_v1:" <>
      Jason.encode!(%{
        "blockers" => Enum.take(blockers, 100),
        "truncated" => length(blockers) > 100
      })
  end

  def blocker(code, node, index, measurements \\ %{}) do
    %{"code" => code, "node_index" => index}
    |> Map.merge(measurements)
    |> maybe_label(node["display_name"])
  end

  def allocation_blockers(result, node, used, demand, index, device_matches) do
    case result do
      {:error, :insufficient_resources} ->
        for {key, code, scale, unit} <- [
              {"memory_mb", "MN_RESOURCE_EXHAUSTED", 1024, "GiB"},
              {"cpu_cores", "MN_CPU_REQUIREMENT_UNMET", 1, "cores"},
              {"disk_mb", "MN_DISK_UNAVAILABLE", 1024, "GiB"},
              {"gpu_count", "MN_GPU_REQUIREMENT_UNMET", 1, "devices"}
            ],
            required = demand["resources"][key] || 0,
            available = max((node["capacity"][key] || 0) - (used["resources"][key] || 0), 0),
            required > available do
          # Busy CPU/GPU reservations are capacity failures, not missing hardware.
          code =
            if key in ["cpu_cores", "gpu_count"] and required <= (node["capacity"][key] || 0),
              do: "MN_RESOURCE_EXHAUSTED",
              else: code

          blocker(code, node, index, %{
            "required" => required / scale,
            "available" => available / scale,
            "unit" => unit,
            "resource" => key
          })
        end

      {:error, :device_unavailable} ->
        blockers =
          device_memory_blockers(node, used, demand["resource_request"], index, device_matches)

        if blockers == [],
          do: [blocker("MN_PLACEMENT_UNSATISFIED", node, index)],
          else: blockers

      {:error, _reason} ->
        [blocker("MN_PLACEMENT_UNSATISFIED", node, index)]

      {:ok, _allocation} ->
        []
    end
  end

  defp device_memory_blockers(node, used, request, index, device_matches) do
    ResourceSpec.scheduling_devices(request)
    |> Enum.filter(&(&1["kind"] == "gpu" and (&1["memory_operator"] || ">=") in [">=", ">"]))
    |> Enum.flat_map(fn needed ->
      required = needed["min_memory_mb"]
      without_memory = Map.put(needed, "min_memory_mb", nil)

      candidates =
        node["devices"]
        |> Enum.reject(&MapSet.member?(used["devices"], &1["id"]))
        |> Enum.filter(&device_matches.(&1, without_memory))

      available =
        candidates
        |> Enum.map(&(&1["memory_free_mb"] || &1["memory_total_mb"]))
        |> Enum.filter(&is_number/1)
        |> Enum.max(fn -> nil end)

      if is_number(required) and is_number(available) and
           not HardwareRequirements.memory_matches?(
             available,
             required,
             needed["memory_operator"] || ">="
           ) do
        [
          blocker("MN_GPU_MEMORY_UNAVAILABLE", node, index, %{
            "required" => required / 1024,
            "available" => available / 1024,
            "unit" => "GiB",
            "resource" => "gpu_memory_free_mb",
            "operator" => needed["memory_operator"] || ">="
          })
        ]
      else
        []
      end
    end)
  end

  defp maybe_label(blocker, label) when is_binary(label) do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9 ._-]{0,63}\z/, label) and
         Regex.match?(~r/[a-zA-Z]/, label),
       do: Map.put(blocker, "node_label", label),
       else: blocker
  end

  defp maybe_label(blocker, _label), do: blocker
end
