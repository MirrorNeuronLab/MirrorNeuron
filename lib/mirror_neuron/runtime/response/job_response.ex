defmodule MirrorNeuron.Runtime.JobResponse do
  use GenServer, restart: :permanent

  @moduledoc "Owner-scoped response service process with asynchronous preparation and bounded public calls."

  alias MirrorNeuron.Runtime.JobResponse.Lifecycle
  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Runtime.JobResponse.Queries
  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.JobResponse.Status
  alias MirrorNeuron.Runtime.JobResponse.Warmup

  @warm_timeout 1_230_000

  defdelegate enabled?(definition), to: Lifecycle
  defdelegate ensure_started(definition), to: Lifecycle
  defdelegate definition_changed(definition), to: Lifecycle
  defdelegate stop(definition), to: Lifecycle
  defdelegate stop(definition, opts), to: Lifecycle
  defdelegate reset(definition), to: Lifecycle
  defdelegate query(job_id, attrs), to: Queries
  defdelegate query_local(job_id, attrs), to: Queries
  defdelegate get_turn(job_id, turn_id), to: Queries
  defdelegate get_turn_local(job_id, turn_id), to: Queries
  defdelegate status(definition), to: Status
  defdelegate status_local(job_id), to: Status

  def start_link(definition) when is_map(definition) do
    GenServer.start_link(__MODULE__, definition, name: Lifecycle.via(definition["job_id"]))
  end

  def child_spec(definition) do
    %{
      id: {__MODULE__, definition["job_id"]},
      start: {__MODULE__, :start_link, [definition]},
      restart: :permanent,
      shutdown: 30_000,
      type: :worker
    }
  end

  @impl true
  def init(definition) do
    now = Runtime.timestamp()
    send(self(), :warm)

    {:ok,
     %{
       definition: definition,
       revision: definition["revision"],
       state: "starting",
       started_at: now,
       updated_at: now,
       ready_at: nil,
       stopped_at: nil,
       safe_error_code: nil,
       retry_ms: 1_000,
       warm_task: nil,
       warm_timer: nil
     }}
  end

  @impl true
  def handle_info(:warm, %{warm_task: task} = state) when not is_nil(task), do: {:noreply, state}

  def handle_info(:warm, state) do
    if state.warm_timer, do: Process.cancel_timer(state.warm_timer)
    parent = self()
    revision = state.revision
    started = System.monotonic_time(:millisecond)
    token = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          ModelServices.job_response_command(
            Warmup.start_payload(state.definition),
            @warm_timeout
          )

        send(parent, {:warm_result, token, revision, result, started})
      end)

    {:noreply, %{state | warm_timer: nil, warm_task: {pid, ref, token}}}
  end

  def handle_info(
        {:warm_result, token, revision, result, started},
        %{warm_task: {_pid, ref, token}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = %{state | warm_task: nil}

    if revision == state.revision do
      Warmup.apply_warm_result(result, started, state)
    else
      send(self(), :warm)
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{warm_task: {_task, ref, _token}} = state
      ) do
    Warmup.apply_warm_result({:error, reason}, System.monotonic_time(:millisecond), %{
      state
      | warm_task: nil
    })
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, Status.public_state(state), state}

  @impl true
  def handle_cast({:query_result, service_state, error_code}, state) do
    next = %{
      state
      | state: service_state,
        updated_at: Runtime.timestamp(),
        safe_error_code: error_code
    }

    # A restarted native responder has lost its engines even if this owner
    # process was ready. Re-establish the same definition without replaying
    # the failed request or its effects. Semantic degraded answers are not
    # transport failures and do not need another warm-up.
    {:noreply,
     if(service_state == "degraded" and not is_nil(error_code),
       do: Warmup.schedule_warm_retry(next),
       else: next
     )}
  end

  def handle_cast({:definition, definition}, state) do
    if definition["revision"] == state.revision do
      {:noreply, state}
    else
      send(self(), :warm)

      {:noreply,
       %{
         state
         | definition: definition,
           revision: definition["revision"],
           state: "starting",
           updated_at: Runtime.timestamp(),
           safe_error_code: nil
       }}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.warm_task, do: Process.exit(elem(state.warm_task, 0), :kill)

    _ =
      ModelServices.job_response_command(
        %{
          "kind" => "job_response",
          "operation" => "stop",
          "job_id" => state.definition["job_id"],
          "force" => true
        },
        27_000
      )

    :ok
  end
end
