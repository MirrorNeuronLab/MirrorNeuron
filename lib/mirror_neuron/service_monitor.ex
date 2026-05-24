defmodule MirrorNeuron.ServiceMonitor do
  @moduledoc false

  use GenServer
  require Logger

  alias MirrorNeuron.ServiceCheck
  alias MirrorNeuron.ServiceRegistry

  @default_interval_ms 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(:mirror_neuron, :service_check_interval_ms, @default_interval_ms)
        )
    }

    schedule_tick(100)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    refresh_services()
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def refresh_services do
    case ServiceRegistry.list() do
      {:ok, services} ->
        services
        |> Enum.filter(&(Map.get(&1, "checks", []) != []))
        |> Enum.each(&refresh_service/1)

        :ok

      {:error, reason} ->
        Logger.debug("service monitor could not list services: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp refresh_service(service) do
    health = ServiceCheck.check_service(service, bundle_root: Map.get(service, "bundle_root"))

    case ServiceRegistry.update_health(service["id"], health) do
      {:ok, updated} ->
        maybe_emit_health_event(service, updated, health)

      {:error, reason} ->
        Logger.warning("failed to update service health #{service["id"]}: #{inspect(reason)}")
    end
  end

  defp maybe_emit_health_event(previous, updated, health) do
    if Map.get(previous, "status") != Map.get(updated, "status") do
      job_id = Map.get(updated, "job_id")

      if is_binary(job_id) and job_id != "" do
        MirrorNeuron.Runtime.EventBus.publish(job_id, %{
          type: :service_health_changed,
          service_id: Map.get(updated, "id"),
          service_name: Map.get(updated, "name"),
          status: Map.get(updated, "status"),
          previous_status: Map.get(previous, "status"),
          health: health,
          timestamp: timestamp()
        })
      end
    end
  end

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, max(interval_ms, 0))

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
