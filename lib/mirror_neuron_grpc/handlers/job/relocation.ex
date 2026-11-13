defmodule MirrorNeuron.Grpc.Handlers.Job.Relocation do
  @moduledoc "Routes relocation phases without introducing circular ownership checks."

  alias MirrorNeuron.Grpc.Handlers.Job.Encoding
  alias MirrorNeuron.Grpc.Handlers.Job.Remote

  def relocate_job(request, stream) do
    # Stage/inspect/activate address a physical node directly. Following the
    # source redirect here would make ownership-commit verification circular.
    local_transfer =
      case MirrorNeuron.Runtime.StableJob.get(request.job_id) do
        {:ok, %{"status" => "relocated", "relocation" => journal}} ->
          request.target_node == journal["target_node"]

        _ ->
          false
      end

    if request.action in ["move", "abort"] and not local_transfer and
         Remote.remote_job_owner(request.job_id) do
      Remote.forward_call(Remote.remote_job_owner(request.job_id), :relocate_job, request, stream)
    else
      MirrorNeuron.Runtime.JobRelocation.command(request) |> Encoding.respond()
    end
  end
end
