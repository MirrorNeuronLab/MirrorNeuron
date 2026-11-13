defmodule MirrorNeuron.Cluster.Hardware do
  @moduledoc "Hardware snapshot and inventory parsing API."

  alias MirrorNeuron.Cluster.Hardware.GpuParsers
  alias MirrorNeuron.Cluster.Hardware.Snapshots

  defdelegate update_snapshot(hardware), to: Snapshots
  defdelegate clear_snapshot(), to: Snapshots
  defdelegate info(), to: Snapshots
  defdelegate parse_darwin_gpu(output), to: GpuParsers
  defdelegate parse_darwin_gpu(output, memory), to: GpuParsers
  defdelegate parse_nvidia_gpu(output), to: GpuParsers
  defdelegate parse_nvidia_gpu(output, memory), to: GpuParsers
  defdelegate parse_nvidia_gpu(output, memory, driver_info), to: GpuParsers
  defdelegate parse_lspci_gpu(output), to: GpuParsers
  defdelegate parse_lspci_gpu(output, rocm_version), to: GpuParsers
end
