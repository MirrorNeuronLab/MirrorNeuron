defmodule MirrorNeuron.Resource do
  @moduledoc false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ResourceSpec

  @allowed_percentages [25, 50, 75, 100]
  @resource_types ["cpu", "gpu", "memory", "disk"]

  def list do
    limits = limits()
    nodes = nodes_provider().resource_nodes() |> List.wrap() |> Enum.map(&node_resource/1)
    totals = totals(nodes)

    %{
      "mode" => if(length(nodes) > 1, do: "cluster", else: "single_node"),
      "node_count" => length(nodes),
      "limits" => limits,
      "combined" => totals,
      "totals" => totals,
      "nodes" => nodes
    }
    |> put_usable_totals()
  end

  def set(attrs) when is_map(attrs) do
    with {:ok, updates} <- normalize_limits(attrs),
         next_limits <- Map.merge(limits(), updates),
         {:ok, persisted} <- store().persist_resource_limits(next_limits) do
      wake_blocked_recovery_evals()
      {:ok, Map.put(list(), "limits", persisted) |> put_usable_totals()}
    end
  end

  def set(_attrs), do: {:error, "resource limits must be an object"}

  def limits do
    case store().fetch_resource_limits() do
      {:ok, stored} when is_map(stored) ->
        default_limits()
        |> Map.merge(valid_limit_values(stored))

      _ ->
        default_limits()
    end
  end

  def limit_ratio(resource_type) do
    resource_type = to_string(resource_type)
    Map.get(limits(), resource_type, 100) / 100
  end

  def resource_nodes, do: MirrorNeuron.inspect_nodes()

  def allowed_percentages, do: @allowed_percentages
  def default_limits, do: Map.new(@resource_types, &{&1, 100})

  defp put_usable_totals(report) do
    limits = Map.fetch!(report, "limits")
    totals = Map.fetch!(report, "totals")

    usable = %{
      "cpu_cores" => percent_of(totals["cpu_cores"], limits["cpu"]),
      "gpu_count" => percent_of(totals["gpu_count"], limits["gpu"]),
      "gpu_memory_total_mb" => percent_of(totals["gpu_memory_total_mb"], limits["gpu"]),
      "gpu_memory_free_mb" => percent_of(totals["gpu_memory_free_mb"], limits["gpu"]),
      "gpu_memory_total_gb" => percent_of(totals["gpu_memory_total_gb"], limits["gpu"]),
      "gpu_memory_free_gb" => percent_of(totals["gpu_memory_free_gb"], limits["gpu"]),
      "memory_gb" => percent_of(totals["memory_total_gb"], limits["memory"]),
      "memory_total_gb" => percent_of(totals["memory_total_gb"], limits["memory"]),
      "memory_available_gb" => percent_of(totals["memory_available_gb"], limits["memory"]),
      "disk_gb" => percent_of(totals["disk_gb"], limits["disk"]),
      "disk_available_gb" => percent_of(totals["disk_available_gb"], limits["disk"])
    }

    Map.put(report, "usable", usable)
  end

  defp node_resource(node) when is_map(node) do
    hardware = Map.get(node, :hardware) || Map.get(node, "hardware") || %{}
    cpu = map_get(hardware, "cpu") || %{}
    memory = map_get(hardware, "memory") || %{}
    gpu = map_get(hardware, "gpu")
    disk = map_get(hardware, "disk") || %{}
    platform = map_get(hardware, "platform") || %{}
    devices = ResourceSpec.normalize_node_devices(%{"hardware" => hardware})
    host_paths = ResourceSpec.normalize_node_host_paths(node, hardware)
    runtime_drivers = ResourceSpec.normalize_node_runtime_drivers(node, hardware)
    name = Map.get(node, :name) || Map.get(node, "name") || "unknown"
    memory_total_gb = memory_gb(memory)
    memory_available_gb = memory_available_gb(memory)
    gpu_memory_total_mb = gpu_memory_total_mb(devices)
    gpu_memory_free_mb = gpu_memory_free_mb(devices)
    gpu_models = gpu_models(devices, gpu)

    %{
      "name" => name,
      "display_name" => node_display_name(node, platform, name),
      "hostname" =>
        Map.get(node, :hostname) || Map.get(node, "hostname") || map_get(platform, "hostname"),
      "platform" => platform_summary(platform),
      "self" => node_attr(node, :self?, false) || node_attr(node, :self, false),
      "status" => Map.get(node, :status) || Map.get(node, "status") || "healthy",
      "scheduling_eligible" => node_attr(node, :scheduling_eligible, true),
      "drain" => Map.get(node, :drain) || Map.get(node, "drain"),
      "cpu_cores" => integer_value(map_get(cpu, "logical_processors")),
      "cpu_model" => cpu_model(cpu),
      "gpu_count" => gpu_count(gpu),
      "gpu_model" => List.first(gpu_models),
      "gpu_models" => gpu_models,
      "memory_gb" => memory_total_gb,
      "memory_total_gb" => memory_total_gb,
      "memory_available_gb" => memory_available_gb,
      "disk_gb" => disk_gb(disk),
      "disk_available_gb" => disk_available_gb(disk),
      "gpu" => gpu_summary(gpu),
      "devices" => devices,
      "gpu_memory_total_mb" => gpu_memory_total_mb,
      "gpu_memory_free_mb" => gpu_memory_free_mb,
      "gpu_memory_total_gb" => mb_to_gb(gpu_memory_total_mb),
      "gpu_memory_free_gb" => mb_to_gb(gpu_memory_free_mb),
      "drivers" => device_drivers(devices, runtime_drivers),
      "runtime_drivers" => runtime_drivers,
      "host_paths" => host_paths
    }
  end

  defp node_resource(_node) do
    %{
      "name" => "unknown",
      "platform" => %{},
      "cpu_cores" => 0,
      "cpu_model" => nil,
      "gpu_count" => 0,
      "gpu_model" => nil,
      "gpu_models" => [],
      "memory_gb" => 0.0,
      "memory_total_gb" => 0.0,
      "memory_available_gb" => 0.0,
      "disk_gb" => 0.0,
      "disk_available_gb" => 0.0,
      "gpu" => [],
      "devices" => [],
      "gpu_memory_total_mb" => 0,
      "gpu_memory_free_mb" => 0,
      "gpu_memory_total_gb" => 0.0,
      "gpu_memory_free_gb" => 0.0,
      "drivers" => [],
      "runtime_drivers" => [],
      "host_paths" => []
    }
  end

  defp node_attr(node, key, default) when is_map(node) do
    cond do
      Map.has_key?(node, key) -> Map.get(node, key)
      Map.has_key?(node, Atom.to_string(key)) -> Map.get(node, Atom.to_string(key))
      true -> default
    end
  end

  defp node_display_name(node, platform, fallback) do
    Map.get(node, :display_name) ||
      Map.get(node, "display_name") ||
      map_get(platform, "display_name") ||
      map_get(platform, "hostname") ||
      fallback
  end

  defp totals(nodes) do
    gpu_memory_total_mb = round_float(Enum.sum(Enum.map(nodes, & &1["gpu_memory_total_mb"])))
    gpu_memory_free_mb = round_float(Enum.sum(Enum.map(nodes, & &1["gpu_memory_free_mb"])))
    memory_total_gb = round_float(Enum.sum(Enum.map(nodes, & &1["memory_total_gb"])))
    memory_available_gb = round_float(Enum.sum(Enum.map(nodes, & &1["memory_available_gb"])))

    %{
      "cpu_cores" => Enum.sum(Enum.map(nodes, & &1["cpu_cores"])),
      "gpu_count" => Enum.sum(Enum.map(nodes, & &1["gpu_count"])),
      "gpu_memory_total_mb" => gpu_memory_total_mb,
      "gpu_memory_free_mb" => gpu_memory_free_mb,
      "gpu_memory_total_gb" => mb_to_gb(gpu_memory_total_mb),
      "gpu_memory_free_gb" => mb_to_gb(gpu_memory_free_mb),
      "memory_gb" => memory_total_gb,
      "memory_total_gb" => memory_total_gb,
      "memory_available_gb" => memory_available_gb,
      "disk_gb" => round_float(Enum.sum(Enum.map(nodes, & &1["disk_gb"]))),
      "disk_available_gb" => round_float(Enum.sum(Enum.map(nodes, & &1["disk_available_gb"])))
    }
  end

  defp normalize_limits(attrs) do
    updates =
      attrs
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        key = normalize_key(key)

        cond do
          key not in @resource_types ->
            {:halt, {:error, "resource type must be one of cpu, gpu, memory, or disk"}}

          normalized = normalize_percentage(value) ->
            {:cont, {:ok, Map.put(acc, key, normalized)}}

          true ->
            allowed = Enum.join(@allowed_percentages, ", ")
            {:halt, {:error, "#{key} must be one of #{allowed}"}}
        end
      end)

    case updates do
      {:ok, values} when map_size(values) > 0 -> {:ok, values}
      {:ok, _values} -> {:error, "at least one of cpu, gpu, memory, or disk is required"}
      error -> error
    end
  end

  defp valid_limit_values(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = normalize_key(key)

      if key in @resource_types and normalize_percentage(value) do
        Map.put(acc, key, normalize_percentage(value))
      else
        acc
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()
  defp normalize_key(key) when is_binary(key), do: key |> String.downcase() |> String.trim()
  defp normalize_key(key), do: to_string(key)

  defp normalize_percentage(value) when is_integer(value) and value in @allowed_percentages,
    do: value

  defp normalize_percentage(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> normalize_percentage(integer)
      _ -> nil
    end
  end

  defp normalize_percentage(_value), do: nil

  defp gpu_count(gpus) when is_list(gpus), do: length(gpus)

  defp gpu_count(gpu) when is_binary(gpu) do
    if unknown_gpu?(gpu), do: 0, else: 1
  end

  defp gpu_count(_gpu), do: 0

  defp gpu_summary(gpus) when is_list(gpus) do
    Enum.map(gpus, fn
      gpu when is_map(gpu) -> Map.get(gpu, :name) || Map.get(gpu, "name") || gpu
      gpu -> gpu
    end)
  end

  defp gpu_summary(gpu) when is_binary(gpu) do
    if unknown_gpu?(gpu), do: [], else: [gpu]
  end

  defp gpu_summary(_gpu), do: []

  defp cpu_model(cpu) when is_map(cpu) do
    map_get(cpu, "model") ||
      map_get(cpu, "model_name") ||
      map_get(cpu, "brand") ||
      map_get(cpu, "processor")
  end

  defp cpu_model(_cpu), do: nil

  defp gpu_models(devices, gpu) do
    device_models =
      devices
      |> Enum.map(&(map_get(&1, "model") || map_get(&1, "name")))

    (device_models ++ gpu_summary(gpu))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or unknown_gpu?(&1)))
    |> Enum.uniq()
  end

  defp gpu_memory_total_mb(devices),
    do: devices |> Enum.map(&(&1["memory_total_mb"] || 0)) |> Enum.sum()

  defp gpu_memory_free_mb(devices),
    do: devices |> Enum.map(&(&1["memory_free_mb"] || 0)) |> Enum.sum()

  defp mb_to_gb(value) when is_number(value), do: round_float(value / 1024)
  defp mb_to_gb(_value), do: 0.0

  defp device_drivers(devices, runtime_drivers) do
    (runtime_drivers ++ Enum.map(devices, & &1["driver"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp unknown_gpu?(gpu) do
    normalized = String.downcase(gpu)

    Enum.any?(["unknown", "none", "unsupported", "not available"], fn marker ->
      String.contains?(normalized, marker)
    end)
  end

  defp platform_summary(platform) when is_map(platform) do
    %{
      "family" => map_get(platform, "family"),
      "os" => map_get(platform, "os"),
      "node" => map_get(platform, "node"),
      "hostname" => map_get(platform, "hostname"),
      "display_name" => map_get(platform, "display_name")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
  end

  defp platform_summary(_platform), do: %{}

  defp memory_gb(memory) when is_map(memory) do
    cond do
      bytes = map_get(memory, "total_bytes") ->
        round_float(bytes / (1024 * 1024 * 1024))

      mb = map_get(memory, "total_mb") ->
        round_float(mb / 1024)

      true ->
        0.0
    end
  end

  defp memory_gb(_memory), do: 0.0

  defp memory_available_gb(memory) when is_map(memory) do
    cond do
      bytes = map_get(memory, "available_bytes") ->
        round_float(bytes / (1024 * 1024 * 1024))

      mb = map_get(memory, "available_mb") ->
        round_float(mb / 1024)

      true ->
        0.0
    end
  end

  defp memory_available_gb(_memory), do: 0.0

  defp disk_gb(disk) when is_map(disk) do
    cond do
      bytes = map_get(disk, "total_bytes") ->
        round_float(bytes / (1024 * 1024 * 1024))

      mb = map_get(disk, "total_mb") ->
        round_float(mb / 1024)

      true ->
        0.0
    end
  end

  defp disk_gb(_disk), do: 0.0

  defp disk_available_gb(disk) when is_map(disk) do
    cond do
      bytes = map_get(disk, "available_bytes") ->
        round_float(bytes / (1024 * 1024 * 1024))

      mb = map_get(disk, "available_mb") ->
        round_float(mb / 1024)

      true ->
        disk_gb(disk)
    end
  end

  defp disk_available_gb(_disk), do: 0.0

  defp percent_of(value, percent) when is_integer(value), do: floor(value * percent / 100)
  defp percent_of(value, percent) when is_float(value), do: round_float(value * percent / 100)
  defp percent_of(_value, _percent), do: 0

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_float(value), do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp integer_value(_value), do: 0

  defp map_get(map, key) when is_map(map), do: MirrorNeuron.SafeAccess.map_get(map, key)

  defp map_get(_map, _key), do: nil

  defp round_float(value) when is_number(value), do: Float.round(value / 1, 2)
  defp round_float(_value), do: 0.0

  defp store do
    Application.get_env(:mirror_neuron, :resource_limits_store, RedisStore)
  end

  defp nodes_provider do
    Application.get_env(:mirror_neuron, :resource_nodes_provider, __MODULE__)
  end

  defp wake_blocked_recovery_evals do
    if Process.whereis(MirrorNeuron.Redis.Connection) do
      _ = MirrorNeuron.Cluster.Reconciler.wake_blocked_evals(reason: "resource limits changed")
    end

    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end
end
