defmodule MirrorNeuron.Grpc.Handlers.Observability do
  @moduledoc false

  @interface_version 1

  alias Mirrorneuron.Observability.V1.EventResponse
  alias MirrorNeuron.Cluster.{FederatedJobRouting, FederationClient}
  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.Runtime.EventBus

  def stream_events(request, stream, dependencies \\ []) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("StreamEvents")

    owner_lookup = Keyword.get(dependencies, :owner_lookup, &remote_event_owner/1)

    case owner_lookup.(request.job_id) do
      nil -> stream_local_events(request, stream, dependencies)
      owner -> stream_remote_events(owner, request, stream, dependencies)
    end
  end

  defp stream_local_events(request, stream, dependencies) do
    local_stream = Keyword.get(dependencies, :local_stream)

    if is_function(local_stream, 2) do
      local_stream.(request, stream)
    else
      do_stream_local_events(request, stream)
    end
  end

  defp do_stream_local_events(request, stream) do
    job_id = request.job_id
    follow? = Map.get(request, :follow, false)
    heartbeat_interval_ms = max(Map.get(request, :heartbeat_interval_ms, 0), 0)
    event_limit = max(Map.get(request, :limit, 0), 0)
    event_start = if event_limit > 0, do: -event_limit, else: 0

    if follow? do
      EventBus.subscribe(job_id)
    end

    terminal? =
      case RedisStore.read_events(job_id, event_start, -1) do
        {:ok, events} ->
          Enum.each(events, fn ev ->
            GRPC.Server.send_reply(stream, event_response(ev))
          end)

          Enum.any?(events, &terminal_event?/1)

        _ ->
          false
      end

    if follow? and not terminal? do
      stream_live_events(job_id, stream, heartbeat_interval_ms)
    else
      stream
    end
  end

  defp stream_remote_events(owner, request, stream, dependencies) do
    if MirrorNeuron.Grpc.Auth.federation_hop(stream) > 0 do
      raise GRPC.RPCError,
        status: GRPC.Status.failed_precondition(),
        message: "MN_FEDERATION_LOOP: forwarded request cannot be forwarded again"
    end

    relay = Keyword.get(dependencies, :relay, &FederationClient.stream_events/3)
    send_reply = Keyword.get(dependencies, :send_reply, &GRPC.Server.send_reply/2)

    :ok = relay.(owner, request, fn response -> send_reply.(stream, response) end)
    stream
  end

  defp remote_event_owner(resource_id) do
    FederatedJobRouting.run_owner(resource_id) || FederatedJobRouting.job_owner(resource_id)
  end

  defp stream_live_events(job_id, stream, heartbeat_interval_ms) do
    receive do
      {:mirror_neuron_event, event} ->
        GRPC.Server.send_reply(stream, event_response(event))

        if terminal_event?(event) do
          stream
        else
          stream_live_events(job_id, stream, heartbeat_interval_ms)
        end
    after
      heartbeat_timeout(heartbeat_interval_ms) ->
        if heartbeat_interval_ms > 0 do
          GRPC.Server.send_reply(
            stream,
            event_response(%{
              type: "stream_heartbeat",
              job_id: job_id,
              timestamp: MirrorNeuron.Runtime.timestamp()
            })
          )
        end

        stream_live_events(job_id, stream, heartbeat_interval_ms)
    end
  rescue
    _ -> stream
  end

  defp heartbeat_timeout(interval) when is_integer(interval) and interval > 0, do: interval
  defp heartbeat_timeout(_interval), do: :infinity

  defp terminal_event?(event) when is_map(event) do
    event_type = Map.get(event, "type") || Map.get(event, :type)
    to_string(event_type) in ["job_completed", "job_failed", "job_cancelled"]
  end

  defp terminal_event?(_event), do: false

  defp event_response(event) when is_map(event) do
    %EventResponse{
      event_json: event |> Map.put_new("version", @interface_version) |> Jason.encode!(),
      version: @interface_version
    }
  end

  defp event_response(event) do
    %EventResponse{event_json: Jason.encode!(event), version: @interface_version}
  end
end
