defmodule MirrorNeuron.Cluster.Hardware.GpuProfile do
  @moduledoc "Derives GPU driver, API version and capability identity from declared profiles."

  alias MirrorNeuron.Config
  alias MirrorNeuron.Cluster.Hardware.Values

  def generic_gpu_devices(0, _memory), do: []

  def generic_gpu_devices(count, memory) when is_integer(count) and count > 0 do
    profile = configured_gpu_profile()

    for index <- 0..(count - 1) do
      %{
        id: "gpu-#{index}",
        index: index,
        name: profile.name || "GPU #{index + 1}",
        model: profile.name || "GPU #{index + 1}",
        kind: "gpu",
        type: profile.type,
        vendor: profile.vendor,
        driver: profile.driver,
        memory_total_mb: Values.number_value(Values.map_get(memory, "total_mb")),
        memory_free_mb: Values.number_value(Values.map_get(memory, "available_mb")),
        api: profile.api,
        api_version: profile.api_version,
        driver_version: profile.driver_version,
        gpu_type: profile.gpu_type,
        capabilities: profile.capabilities
      }
    end
  end

  def generic_gpu_devices(_count, _memory), do: []

  defp configured_gpu_profile do
    identity =
      [
        Config.optional_string("MN_NODE_GPU_NAME", :node_gpu_name),
        Config.optional_string("MN_NODE_GPU_VENDOR", :node_gpu_vendor),
        Config.optional_string("MN_NODE_GPU_DRIVER", :node_gpu_driver),
        Config.optional_string("MN_NODE_GPU_TYPE", :node_gpu_type),
        Config.optional_string("MN_NODE_GPU_API_VERSION", :node_gpu_api_version),
        Config.optional_string("MN_NODE_GPU_DRIVER_VERSION", :node_gpu_driver_version),
        Config.list("MN_NODE_CAPABILITIES", :node_capabilities) |> Enum.join(" "),
        Config.optional_string("MN_NODE_DISPLAY_NAME", :node_display_name)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    normalized = String.downcase(identity)

    vendor =
      normalize_gpu_vendor(Config.optional_string("MN_NODE_GPU_VENDOR", :node_gpu_vendor)) ||
        inferred_gpu_vendor(normalized)

    driver =
      normalize_gpu_driver(Config.optional_string("MN_NODE_GPU_DRIVER", :node_gpu_driver)) ||
        driver_from_gpu_vendor(vendor)

    type =
      Config.optional_string("MN_NODE_GPU_TYPE", :node_gpu_type) || type_from_gpu_vendor(vendor)

    name =
      Config.optional_string("MN_NODE_GPU_NAME", :node_gpu_name) ||
        inferred_gpu_name(vendor, normalized)

    api = api_from_gpu_driver(driver)

    api_version =
      Config.optional_string("MN_NODE_GPU_API_VERSION", :node_gpu_api_version) ||
        inferred_api_version(driver, normalized)

    driver_version =
      Config.optional_string("MN_NODE_GPU_DRIVER_VERSION", :node_gpu_driver_version)

    %{
      name: name,
      type: type,
      vendor: vendor || "generic",
      driver: driver,
      api: api,
      api_version: api_version,
      driver_version: driver_version,
      gpu_type: gpu_type(vendor, api || driver, api_version),
      capabilities: configured_gpu_capabilities(vendor, driver, normalized)
    }
  end

  def configured_gpu_capabilities(vendor, driver, normalized) do
    (["gpu", vendor, driver] ++
       Config.list("MN_NODE_CAPABILITIES", :node_capabilities) ++
       inferred_gpu_capabilities(vendor, normalized))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Values.normalize_capability/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp inferred_gpu_capabilities("nvidia", normalized),
    do: ["nvidia", "cuda"] ++ nvidia_gpu_capabilities(normalized)

  defp inferred_gpu_capabilities("apple", normalized),
    do: ["apple", "metal", "unified_memory"] ++ apple_gpu_capabilities(normalized)

  defp inferred_gpu_capabilities("amd", _normalized), do: ["amd", "rocm"]

  defp inferred_gpu_capabilities("intel", _normalized), do: ["intel"]

  defp inferred_gpu_capabilities(_vendor, _normalized), do: ["generic"]

  defp inferred_gpu_vendor(normalized) do
    cond do
      String.contains?(normalized, "nvidia") or String.contains?(normalized, "cuda") or
        String.contains?(normalized, "dgx spark") or String.contains?(normalized, "gb10") or
          String.contains?(normalized, "spark") ->
        "nvidia"

      String.contains?(normalized, "apple") or String.contains?(normalized, "metal") or
        String.contains?(normalized, "macbook") or String.contains?(normalized, "mac mini") or
          String.contains?(normalized, "mac studio") ->
        "apple"

      String.contains?(normalized, "amd") or String.contains?(normalized, "radeon") or
          String.contains?(normalized, "rocm") ->
        "amd"

      String.contains?(normalized, "intel") ->
        "intel"

      true ->
        nil
    end
  end

  defp inferred_gpu_name("nvidia", normalized) do
    cond do
      String.contains?(normalized, "dgx spark") or String.contains?(normalized, "spark") ->
        "NVIDIA DGX Spark"

      String.contains?(normalized, "gb10") ->
        "NVIDIA GB10"

      true ->
        nil
    end
  end

  defp inferred_gpu_name("apple", _normalized), do: "Apple Metal GPU"

  defp inferred_gpu_name(_vendor, _normalized), do: nil

  defp normalize_gpu_vendor(nil), do: nil

  defp normalize_gpu_vendor(value) do
    case Values.normalize_capability(value) do
      value when value in ["nvidia", "amd", "apple", "intel"] -> value
      _ -> nil
    end
  end

  defp normalize_gpu_driver(nil), do: nil

  defp normalize_gpu_driver(value) do
    case Values.normalize_capability(value) do
      value when value in ["cuda", "rocm", "metal", "intel", "generic"] -> value
      _ -> nil
    end
  end

  def driver_from_gpu_vendor("nvidia"), do: "cuda"

  def driver_from_gpu_vendor("amd"), do: "rocm"

  def driver_from_gpu_vendor("apple"), do: "metal"

  def driver_from_gpu_vendor("intel"), do: "intel"

  def driver_from_gpu_vendor(_vendor), do: "generic"

  def api_from_gpu_driver("cuda"), do: "cuda"

  def api_from_gpu_driver("rocm"), do: "rocm"

  def api_from_gpu_driver("metal"), do: "metal"

  def api_from_gpu_driver(_driver), do: nil

  defp inferred_api_version(driver, normalized) do
    cond do
      driver == "cuda" -> Values.version_after(normalized, "cuda")
      driver == "rocm" -> Values.version_after(normalized, "rocm")
      true -> nil
    end
  end

  def gpu_type("nvidia", "cuda", version), do: versioned_type("nvidia-cuda", version)

  def gpu_type("amd", "rocm", version), do: versioned_type("amd-rocm", version)

  def gpu_type("apple", "metal", _version), do: "mac-metal"

  def gpu_type("intel", _api, _version), do: "intel"

  def gpu_type(_vendor, _api, _version), do: "generic"

  defp versioned_type(prefix, nil), do: prefix

  defp versioned_type(prefix, ""), do: prefix

  defp versioned_type(prefix, version), do: "#{prefix}-#{version}"

  def type_from_gpu_vendor(nil), do: "generic/gpu"

  def type_from_gpu_vendor("generic"), do: "generic/gpu"

  def type_from_gpu_vendor(vendor), do: "#{vendor}/gpu"

  def nvidia_gpu_capabilities(name) do
    normalized = String.downcase(to_string(name || ""))

    []
    |> maybe_capability(
      String.contains?(normalized, "dgx spark") or String.contains?(normalized, "spark"),
      "nvidia-dgx-spark"
    )
    |> maybe_capability(String.contains?(normalized, "gh200"), "nvidia-gh200")
    |> maybe_capability(String.contains?(normalized, "h100"), "nvidia-h100")
    |> maybe_capability(String.contains?(normalized, "h200"), "nvidia-h200")
    |> maybe_capability(String.contains?(normalized, "b200"), "nvidia-b200")
    |> maybe_capability(String.contains?(normalized, "gb10"), "nvidia-gb10")
    |> maybe_capability(String.contains?(normalized, "gb200"), "nvidia-gb200")
  end

  def apple_gpu_capabilities(name) do
    normalized = String.downcase(to_string(name || ""))

    []
    |> maybe_capability(String.contains?(normalized, "m1"), "apple-m1")
    |> maybe_capability(String.contains?(normalized, "m2"), "apple-m2")
    |> maybe_capability(String.contains?(normalized, "m3"), "apple-m3")
    |> maybe_capability(String.contains?(normalized, "m4"), "apple-m4")
    |> maybe_capability(String.contains?(normalized, "max"), "apple-max")
    |> maybe_capability(String.contains?(normalized, "ultra"), "apple-ultra")
  end

  defp maybe_capability(capabilities, true, capability), do: [capability | capabilities]

  defp maybe_capability(capabilities, false, _capability), do: capabilities
end
