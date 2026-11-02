defmodule MirrorNeuron.Grpc.Handlers.SignalStream do
  @moduledoc false
  alias MirrorNeuron.Runtime.Signals
  alias MirrorNeuron.Persistence.SignalStore
  alias Mirrorneuron.Observability.V1.EventResponse

  def stream(request, stream) do
    if request.after_sequence < 0,
      do:
        raise(GRPC.RPCError,
          status: GRPC.Status.invalid_argument(),
          message: "negative signal cursor"
        )

    {:ok, flag} = Signals.subscribe(request.job_id, request.channel)

    try do
      loop(request, stream, flag, request.after_sequence)
    after
      Registry.unregister(MirrorNeuron.Runtime.SignalRegistry, {request.job_id, request.channel})
    end
  end

  defp loop(request, stream, flag, cursor) do
    # Rearm before reading: a concurrent append either appears in this read or
    # supplies the next wake-up. Only one wake-up can be queued per subscriber.
    Signals.rearm(flag)

    case SignalStore.read(request.job_id, request.channel, cursor) do
      {:ok, events} ->
        Enum.each(events, fn event ->
          GRPC.Server.send_reply(stream, %EventResponse{
            version: 1,
            event_json: Jason.encode!(event)
          })
        end)

        next =
          case List.last(events) do
            nil -> cursor
            event -> event["sequence"]
          end

        if request.follow, do: wait(request, stream, flag, next), else: stream

      {:error, :signal_replay_gap} ->
        raise GRPC.RPCError,
          status: GRPC.Status.out_of_range(),
          message: "signal_replay_gap: resynchronize from cursor 0"

      {:error, _} ->
        raise GRPC.RPCError,
          status: GRPC.Status.unavailable(),
          message: "signal persistence unavailable"
    end
  end

  defp wait(request, stream, flag, cursor) do
    receive do
      {:runtime_signal_available, _} ->
        loop(request, stream, flag, cursor)

      {:runtime_signal_unavailable, _} ->
        raise GRPC.RPCError,
          status: GRPC.Status.unavailable(),
          message: "signal persistence unconfirmed"
    after
      max(request.heartbeat_interval_ms, 1000) ->
        GRPC.Server.send_reply(stream, %EventResponse{
          version: 1,
          event_json:
            Jason.encode!(%{type: "stream_heartbeat", channel: request.channel, sequence: cursor})
        })

        loop(request, stream, flag, cursor)
    end
  end
end
