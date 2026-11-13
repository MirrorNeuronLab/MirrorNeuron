defmodule MirrorNeuron.Runtime.JobResponse.Lifecycle do
  @moduledoc "Starts and stops the response process only on the stable Job owner."

  require Logger

  alias MirrorNeuron.ModelServices
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Runtime.StableJob
  alias MirrorNeuron.Runtime.JobResponse.Status

  @registry MirrorNeuron.Runtime.JobResponseRegistry
  @supervisor MirrorNeuron.Runtime.JobResponseSupervisor

  def enabled?(definition) when is_map(definition) do
    get_in(definition, ["manifest", "response_service", "enabled"]) === true
  end

  def enabled?(_definition), do: false

  def ensure_started(definition) when is_map(definition) do
    cond do
      not enabled?(definition) or definition["status"] != "active" ->
        stop(definition)

      not local_owner?(definition) ->
        stop(definition)

      not process_ready?(@supervisor) or not process_ready?(@registry) ->
        :ok

      true ->
        case lookup(definition["job_id"]) do
          {:ok, pid} ->
            GenServer.cast(pid, {:definition, definition})
            :ok

          :error ->
            case DynamicSupervisor.start_child(
                   @supervisor,
                   {MirrorNeuron.Runtime.JobResponse, definition}
                 ) do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _pid}} -> :ok
              {:error, :already_present} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  def definition_changed(definition) when is_map(definition), do: ensure_started(definition)

  def stop(definition) when is_map(definition), do: stop(definition, [])

  def stop(job_id) when is_binary(job_id) do
    case StableJob.get(job_id) do
      {:ok, definition} -> stop(definition)
      {:error, _missing} -> terminate_local(job_id)
    end
  end

  def stop(definition, opts) when is_map(definition) and is_list(opts) do
    job_id = definition["job_id"]
    force? = Keyword.get(opts, :force, false)

    result =
      if enabled?(definition) or match?({:ok, _pid}, lookup(job_id)) do
        ModelServices.job_response_command(
          %{
            "kind" => "job_response",
            "operation" => "stop",
            "job_id" => job_id,
            "force" => force?
          },
          if(force?, do: 5_000, else: 27_000)
        )
      else
        {:ok, %{"state" => "disabled"}}
      end

    case result do
      {:ok, _response} ->
        terminate_local(job_id)

      {:error, reason} ->
        if force? or Status.safe_error_code(reason) == "native_unavailable" do
          if force? do
            Logger.warning(
              "forcing response service shutdown for #{job_id} after #{Status.safe_error_code(reason)}"
            )
          end

          terminate_local(job_id)
        else
          {:error, {:response_service_stop_failed, Status.safe_error_code(reason)}}
        end
    end
  end

  defp terminate_local(job_id) do
    case lookup(job_id) do
      {:ok, pid} ->
        try do
          DynamicSupervisor.terminate_child(@supervisor, pid)
        catch
          :exit, _ -> :ok
        end

      :error ->
        :ok
    end
  end

  def reset(definition) when is_map(definition) do
    :ok = stop(definition["job_id"])
    ensure_started(definition)
  end

  def local_owner?(definition),
    do: to_string(NodeAdapter.self()) == to_string(definition["owner_node"])

  def via(job_id), do: {:via, Registry, {@registry, job_id}}

  def lookup(job_id) do
    if process_ready?(@registry) do
      case Registry.lookup(@registry, job_id) do
        [{pid, _value}] -> {:ok, pid}
        _ -> :error
      end
    else
      :error
    end
  end

  defp process_ready?(name), do: not is_nil(Process.whereis(name))
end
