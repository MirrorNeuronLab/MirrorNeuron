defmodule MirrorNeuron.ServiceMonitor do
  @moduledoc false

  use GenServer
  require Logger

  alias MirrorNeuron.ServiceCheck
  alias MirrorNeuron.ServiceRegistry

  @default_interval_ms 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(:mirror_neuron, :service_check_interval_ms, @default_interval_ms)
        ),
      tick_timer_ref: nil,
      tick_token: nil
    }

    {:ok, schedule_tick(state, Keyword.get(opts, :initial_delay_ms, 100))}
  end

  @impl true
  def handle_info({:tick, token}, %{tick_token: token} = state) do
    state = clear_tick_timer(state)
    refresh_services()
    {:noreply, schedule_tick(state, state.interval_ms)}
  end

  def handle_info({:tick, _stale_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    refresh_services()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_tick_timer(state)
    :ok
  end

  def refresh_services do
    case ServiceRegistry.list() do
      {:ok, services} ->
        services
        |> Enum.filter(&refreshable_on_current_node?/1)
        |> Enum.filter(&(Map.get(&1, "checks", []) != []))
        |> Enum.each(&refresh_service/1)

        :ok

      {:error, reason} ->
        Logger.debug("service monitor could not list services: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def refreshable_on_current_node?(service) when is_map(service) do
    case Map.get(service, "node") || Map.get(service, :node) do
      nil -> true
      "" -> true
      node -> to_string(node) == to_string(Node.self())
    end
  end

  defp refresh_service(service) do
    health = ServiceCheck.check_service(service, bundle_root: Map.get(service, "bundle_root"))

    case ServiceRegistry.update_health(service["id"], health) do
      {:ok, updated} ->
        maybe_emit_health_event(service, updated)

      {:error, reason} ->
        Logger.warning("failed to update service health #{service["id"]}: #{inspect(reason)}")
    end
  end

  defp maybe_emit_health_event(previous, updated) do
    if Map.get(previous, "status") != Map.get(updated, "status") do
      job_id = Map.get(updated, "job_id")

      if is_binary(job_id) and job_id != "" do
        MirrorNeuron.Runtime.EventBus.publish(job_id, %{
          type: :service_health_changed,
          service_id: Map.get(updated, "id"),
          service_name: Map.get(updated, "name"),
          status: Map.get(updated, "status"),
          previous_status: Map.get(previous, "status"),
          health: Map.get(updated, "health", %{}),
          timestamp: timestamp()
        })
      end
    end
  end

  defp schedule_tick(state, interval_ms) when is_integer(interval_ms) and interval_ms >= 0 do
    state = cancel_tick_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, token}, interval_ms)
    %{state | tick_timer_ref: timer_ref, tick_token: token}
  end

  defp schedule_tick(state, _interval_ms), do: cancel_tick_timer(state)

  defp cancel_tick_timer(%{tick_timer_ref: ref, tick_token: token} = state)
       when is_reference(ref) do
    Process.cancel_timer(ref)

    receive do
      {:tick, ^token} -> :ok
    after
      0 -> :ok
    end

    clear_tick_timer(state)
  end

  defp cancel_tick_timer(state), do: state

  defp clear_tick_timer(state),
    do: %{state | tick_timer_ref: nil, tick_token: nil}

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
