defmodule MirrorNeuron.Runtime.RunResourceEnvironment do
  @moduledoc false

  # Docker renumbers a restricted physical GPU set from zero. Agent-specific
  # selections must be translated within that set instead of using host indices.
  def for_container(%{"resource_allocation" => %{"mode" => "shared"} = allocation}, env) do
    cuda = Enum.filter(allocation["devices"] || [], &(&1["driver"] == "cuda"))
    selected = String.split(env["MN_ALLOCATED_DEVICE_IDS"] || "", ",", trim: true)

    indices =
      cuda
      |> Enum.with_index()
      |> Enum.filter(fn {device, _} -> selected == [] or device["id"] in selected end)
      |> Enum.map(fn {_, index} -> to_string(index) end)

    Map.put(env, "CUDA_VISIBLE_DEVICES", Enum.join(indices, ","))
  end

  def for_container(_config, env), do: env
end
