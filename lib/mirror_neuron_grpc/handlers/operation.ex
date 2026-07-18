defmodule MirrorNeuron.Grpc.Handlers.Operation do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Persistence.OperationStore

  alias Mirrorneuron.Operations.V1.{
    GetOperationResponse,
    OperationEventResponse,
    StartOperationResponse
  }

  def start_operation(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("StartOperation")

    options = options(request.options_json)

    case MirrorNeuron.start_operation(request.kind, options) do
      {:ok, operation} ->
        %StartOperationResponse{
          operation_json: MirrorNeuron.Grpc.Handlers.Support.versioned_json(operation),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError,
          status: GRPC.Status.invalid_argument(),
          message: MirrorNeuron.Runtime.error_message(reason)
    end
  end

  def get_operation(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetOperation")

    case MirrorNeuron.operation(request.operation_id) do
      {:ok, operation} ->
        %GetOperationResponse{
          operation_json: MirrorNeuron.Grpc.Handlers.Support.versioned_json(operation),
          version: @interface_version
        }

      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.not_found(), message: inspect(reason)
    end
  end

  def stream_operation_events(request, stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("StreamOperationEvents")

    after_sequence = max(Map.get(request, :after_sequence, 0), 0)
    follow? = Map.get(request, :follow, false)
    heartbeat_ms = max(Map.get(request, :heartbeat_interval_ms, 0), 0)

    with {:ok, events} <- MirrorNeuron.operation_events(request.operation_id, after_sequence),
         {:ok, operation} <- MirrorNeuron.operation(request.operation_id) do
      Enum.each(events, &GRPC.Server.send_reply(stream, event_response(&1)))
      latest = latest_sequence(after_sequence, events)

      if follow? and not OperationStore.terminal?(operation) do
        stream_live_events(request.operation_id, latest, stream, heartbeat_ms, monotonic_ms())
      else
        stream
      end
    else
      {:error, reason} ->
        raise GRPC.RPCError, status: GRPC.Status.not_found(), message: inspect(reason)
    end
  end

  defp stream_live_events(operation_id, after_sequence, stream, heartbeat_ms, heartbeat_at) do
    Process.sleep(200)

    case MirrorNeuron.operation_events(operation_id, after_sequence) do
      {:ok, events} ->
        Enum.each(events, &GRPC.Server.send_reply(stream, event_response(&1)))
        next_sequence = latest_sequence(after_sequence, events)

        case MirrorNeuron.operation(operation_id) do
          {:ok, operation} ->
            now = monotonic_ms()

            if OperationStore.terminal?(operation) do
              # Runner status is committed just before its terminal event. Read
              # once more so a client that was following during that tiny
              # window still receives the replayable completion record.
              deliver_terminal_events(operation_id, next_sequence, stream)
            else
              if heartbeat_ms > 0 and now - heartbeat_at >= heartbeat_ms do
                GRPC.Server.send_reply(
                  stream,
                  event_response(%{
                    "type" => "stream_heartbeat",
                    "operation_id" => operation_id,
                    "timestamp" => MirrorNeuron.Runtime.timestamp()
                  })
                )

                stream_live_events(operation_id, next_sequence, stream, heartbeat_ms, now)
              else
                stream_live_events(
                  operation_id,
                  next_sequence,
                  stream,
                  heartbeat_ms,
                  heartbeat_at
                )
              end
            end

          _ ->
            stream
        end

      _ ->
        stream
    end
  rescue
    _ -> stream
  end

  defp options(json) do
    map = MirrorNeuron.Grpc.Handlers.Support.decode_json_map(json)

    [
      node_name: map["node_name"] || map["node"],
      reason: map["reason"],
      dry_run: map["dry_run"],
      deadline_ms: positive_integer(map["deadline_ms"]),
      ignore_system_jobs: map["ignore_system_jobs"]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp deliver_terminal_events(operation_id, after_sequence, stream) do
    case MirrorNeuron.operation_events(operation_id, after_sequence) do
      {:ok, events} ->
        Enum.each(events, &GRPC.Server.send_reply(stream, event_response(&1)))
        stream

      _ ->
        stream
    end
  end

  defp latest_sequence(sequence, []), do: sequence
  defp latest_sequence(_sequence, events), do: events |> List.last() |> Map.get("sequence", 0)

  defp event_response(event),
    do: %OperationEventResponse{event_json: Jason.encode!(event), version: @interface_version}

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
