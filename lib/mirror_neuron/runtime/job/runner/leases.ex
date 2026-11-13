defmodule MirrorNeuron.Runtime.JobRunner.Leases do
  @moduledoc "Fenced run lease acquisition, renewal, release and token-scoped renewal timers."

  require Logger

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.EventBus

  @default_lease_duration_ms 60_000
  @default_lease_renew_interval_ms 10_000
  @max_lease_renew_failures 3

  def lease_duration_ms,
    do:
      config_positive_integer(
        "MN_JOB_LEASE_DURATION_MS",
        :job_lease_duration_ms,
        @default_lease_duration_ms
      )

  def lease_renew_interval_ms,
    do:
      config_positive_integer(
        "MN_JOB_LEASE_RENEW_INTERVAL_MS",
        :job_lease_renew_interval_ms,
        @default_lease_renew_interval_ms
      )

  def renew_lease(state, reschedule?) do
    lease_name = "job:#{state.job_id}"

    case RedisStore.renew_fenced_lease(
           lease_name,
           state.node_name,
           state.lease["epoch"],
           lease_duration_ms()
         ) do
      :ok ->
        state = %{state | lease_failures: 0}
        {:noreply, maybe_schedule_lease_renewal(state, reschedule?)}

      {:error, :not_owner} ->
        Logger.warning("Lost lease for job #{state.job_id}. Shutting down.")

        EventBus.publish(state.job_id, %{
          type: :job_lease_lost,
          lease_epoch: state.lease["epoch"],
          lease_owner: state.node_name,
          timestamp: Runtime.timestamp()
        })

        {:stop, :normal, state}

      {:error, reason} ->
        failures = state.lease_failures + 1

        if failures >= @max_lease_renew_failures do
          Logger.warning(
            "failed to renew lease for job #{state.job_id} #{failures} times; shutting down: #{inspect(reason)}"
          )

          {:stop, {:shutdown, {:lease_unavailable, reason}}, %{state | lease_failures: failures}}
        else
          Logger.warning(
            "failed to renew lease for job #{state.job_id}; retrying: #{inspect(reason)}"
          )

          state = %{state | lease_failures: failures}
          {:noreply, maybe_schedule_lease_renewal(state, reschedule?)}
        end
    end
  end

  def release_job_lease(_job_id, _node_name, nil), do: :ok

  def release_job_lease(job_id, node_name, lease) do
    case RedisStore.release_fenced_lease("job:#{job_id}", node_name, lease["epoch"]) do
      :ok ->
        MirrorNeuron.Runtime.NodeAdmission.wake()

      {:error, :not_owner} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to release lease for job #{job_id}: #{inspect(reason)}")
        :ok
    end
  end

  def acquire_job_lease(lease_name, node_name) do
    case RedisStore.acquire_fenced_lease(lease_name, node_name, lease_duration_ms()) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, {:locked, owner}} ->
        Logger.info("job lease #{lease_name} is already held by #{inspect(owner)}")
        {:error, {:locked, owner}}

      {:error, reason} ->
        {:error, {:lease_unavailable, reason}}
    end
  end

  defp maybe_schedule_lease_renewal(state, true), do: schedule_lease_renewal(state)

  defp maybe_schedule_lease_renewal(state, false), do: state

  def schedule_lease_renewal(state) do
    state = cancel_lease_timer(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:renew_lease, token}, lease_renew_interval_ms())
    %{state | lease_timer_ref: timer_ref, lease_timer_token: token}
  end

  def cancel_lease_timer(state) do
    ref = Map.get(state, :lease_timer_ref)
    token = Map.get(state, :lease_timer_token)

    if is_reference(ref) do
      Process.cancel_timer(ref)

      receive do
        {:renew_lease, ^token} -> :ok
      after
        0 -> :ok
      end
    end

    clear_lease_timer(state)
  end

  def clear_lease_timer(state) do
    state
    |> Map.put(:lease_timer_ref, nil)
    |> Map.put(:lease_timer_token, nil)
  end

  defp config_positive_integer(env_name, key, default) do
    case System.get_env(env_name) do
      nil ->
        app_positive_integer(key, default)

      "" ->
        app_positive_integer(key, default)

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> app_positive_integer(key, default)
        end
    end
  end

  defp app_positive_integer(key, default) do
    case Application.get_env(:mirror_neuron, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
