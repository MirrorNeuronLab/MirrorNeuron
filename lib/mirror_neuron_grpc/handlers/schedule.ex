defmodule MirrorNeuron.Grpc.Handlers.Schedule do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Grpc.Handlers.Support
  alias Mirrorneuron.Job.V1.ScheduleResponse

  def create_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("CreateSchedule")

    with {:ok, tmp_dir} <- Support.request_bundle_dir(request.manifest_json, request.payloads),
         {:ok, schedule} <-
           MirrorNeuron.create_schedule(tmp_dir, Support.decode_json_map(request.schedule_json),
             source: Support.decode_json_map(request.source_json)
           ) do
      schedule_response(schedule)
    else
      {:error, reason} -> raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def update_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("UpdateSchedule")

    schedule_action_response(
      MirrorNeuron.update_schedule(
        request.schedule_id,
        Support.decode_json_map(request.attrs_json)
      )
    )
  end

  def get_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("GetSchedule")
    schedule_action_response(MirrorNeuron.get_schedule(request.schedule_id))
  end

  def list_schedules(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListSchedules")

    opts =
      request.query_json
      |> Support.decode_json_map()
      |> schedule_keyword_opts()

    case MirrorNeuron.list_schedules(opts) do
      {:ok, schedules} -> schedule_response(%{"data" => schedules})
      {:error, reason} -> raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  def pause_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("PauseSchedule")

    schedule_action_response(
      MirrorNeuron.pause_schedule(request.schedule_id, reason: request.reason)
    )
  end

  def resume_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ResumeSchedule")

    schedule_action_response(
      MirrorNeuron.resume_schedule(request.schedule_id, reason: request.reason)
    )
  end

  def delete_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DeleteSchedule")

    case MirrorNeuron.delete_schedule(request.schedule_id, reason: request.reason) do
      :ok -> schedule_response(%{"schedule_id" => request.schedule_id, "status" => "deleted"})
      {:ok, result} -> schedule_response(result)
      {:error, reason} -> raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
    end
  end

  def dispatch_schedule(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("DispatchSchedule")

    schedule_action_response(
      MirrorNeuron.dispatch_schedule(
        request.schedule_id,
        Support.decode_json_map(request.payload_json),
        reason: request.reason
      )
    )
  end

  def emit_trigger_event(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("EmitTriggerEvent")

    schedule_action_response(
      MirrorNeuron.emit_trigger_event(
        request.event_type,
        Support.decode_json_map(request.payload_json),
        source: Support.blank_to_nil(request.source) || "api"
      )
    )
  end

  def list_trigger_events(request, _stream) do
    MirrorNeuron.Grpc.NetworkOnly.reject_if_enabled!("ListTriggerEvents")

    case MirrorNeuron.list_trigger_events(limit: request.limit) do
      {:ok, events} -> schedule_response(%{"data" => events})
      {:error, reason} -> raise GRPC.RPCError, status: :internal, message: inspect(reason)
    end
  end

  defp schedule_action_response({:ok, result}), do: schedule_response(result)

  defp schedule_action_response({:error, reason}) do
    raise GRPC.RPCError, status: :invalid_argument, message: inspect(reason)
  end

  defp schedule_response(result),
    do: %ScheduleResponse{
      result_json: Support.versioned_json(result),
      version: @interface_version
    }

  defp schedule_keyword_opts(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {"kind", value} -> [kind: value]
      {"status", value} -> [status: value]
      {"enabled", value} when is_boolean(value) -> [enabled: value]
      _other -> []
    end)
  end
end
