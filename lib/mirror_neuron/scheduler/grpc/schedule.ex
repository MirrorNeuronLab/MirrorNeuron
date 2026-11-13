defmodule MirrorNeuron.Grpc.Handlers.Schedule do
  @moduledoc false
  alias MirrorNeuron.Cluster.{FederatedJobRouting, FederationClient, NodeAdapter}
  alias MirrorNeuron.Grpc.{Handlers.Support, JobProjection}
  alias MirrorNeuron.Runtime.ScheduleDispatcher
  alias Mirrorneuron.Job.V1.JsonResponse

  def list_schedules(request, stream) do
    route(request, stream, :list_schedules, fn ->
      case ScheduleDispatcher.list_schedules() do
        {:ok, schedules} ->
          respond({:ok, %{"items" => Enum.map(schedules, &JobProjection.schedule/1)}})

        error ->
          respond(error)
      end
    end)
  end

  def get_schedule(request, stream) do
    route(request, stream, :get_schedule, fn ->
      ScheduleDispatcher.get_schedule(request.schedule_id) |> project()
    end)
  end

  def update_schedule(request, stream) do
    route(request, stream, :update_schedule, fn ->
      with {:ok, attrs} <- MirrorNeuron.Grpc.Validation.decode_json_map(request.attrs_json),
           {:ok, record} <- ScheduleDispatcher.get_schedule(request.schedule_id),
           :ok <- revision(record, request.expected_revision) do
        ScheduleDispatcher.update_schedule(request.schedule_id, attrs,
          expected_revision: request.expected_revision
        )
        |> project()
      else
        error -> respond(error)
      end
    end)
  end

  def delete_schedule(request, stream) do
    route(request, stream, :delete_schedule, fn ->
      with {:ok, record} <- ScheduleDispatcher.get_schedule(request.schedule_id),
           :ok <- revision(record, request.expected_revision),
           :ok <-
             ScheduleDispatcher.delete_schedule(request.schedule_id,
               expected_revision: request.expected_revision
             ) do
        respond({:ok, %{"schedule_id" => request.schedule_id, "status" => "cancelled"}})
      else
        error -> respond(error)
      end
    end)
  end

  defp route(request, stream, function, local) do
    explicit = Support.blank_to_nil(request.owner_node)
    local_exists = match?({:ok, _}, ScheduleDispatcher.get_schedule(request.schedule_id))

    owner =
      cond do
        explicit ->
          explicit

        local_exists or function == :list_schedules ->
          nil

        MirrorNeuron.Grpc.Auth.federation_hop(stream) > 0 ->
          Support.raise_runtime_error!(:not_found)

        true ->
          queue_owner(request.schedule_id) ||
            FederationClient.discover_schedule_owner(request.schedule_id)
      end

    if owner && owner != to_string(NodeAdapter.self()) do
      if MirrorNeuron.Grpc.Auth.federation_hop(stream) > 0 do
        raise GRPC.RPCError,
          status: GRPC.Status.failed_precondition(),
          message: "MN_FEDERATION_LOOP"
      end

      FederationClient.call(owner, function, request)
    else
      local.()
    end
  end

  defp queue_owner("queue_" <> run_id), do: FederatedJobRouting.run_owner(run_id)
  defp queue_owner(_), do: nil
  defp revision(_record, 0), do: :ok
  defp revision(%{"revision" => expected}, expected), do: :ok
  defp revision(_, _), do: {:error, :revision_mismatch}
  defp project({:ok, record}), do: respond({:ok, JobProjection.schedule(record)})
  defp project(error), do: respond(error)

  defp respond({:ok, record}),
    do: %JsonResponse{
      version: 1,
      result_json: Jason.encode!(record),
      revision: record["revision"] || 0
    }

  defp respond({:error, reason}), do: Support.raise_runtime_error!(reason)
end
