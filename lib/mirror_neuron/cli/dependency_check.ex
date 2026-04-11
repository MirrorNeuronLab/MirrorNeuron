defmodule MirrorNeuron.CLI.DependencyCheck do
  @moduledoc false

  alias MirrorNeuron.Config

  def verify_service_dependencies do
    with :ok <- check_redis(),
         :ok <- check_openshell() do
      :ok
    end
  end

  def service_command?(["standalone-start"]), do: true
  def service_command?(["server"]), do: true
  def service_command?(["cluster", command | _rest]) when command in ["start", "join"], do: true
  def service_command?(_args), do: false

  defp check_redis do
    redis_url = Config.string("MIRROR_NEURON_REDIS_URL", :redis_url)

    with {:ok, conn} <- Redix.start_link(redis_url),
         {:ok, "PONG"} <- Redix.command(conn, ["PING"]) do
      GenServer.stop(conn, :normal)
      :ok
    else
      {:error, reason} ->
        {:error,
         "Redis is not running or not reachable at #{redis_url}: #{format_reason(reason)}"}

      other ->
        {:error, "Redis ping failed for #{redis_url}: #{inspect(other)}"}
    end
  end

  defp check_openshell do
    executable = Config.string("MIRROR_NEURON_OPENSHELL_BIN", :openshell_bin)
    do_check_openshell(executable)
  end

  defp do_check_openshell(executable) do
    case System.find_executable(executable) do
      nil ->
        {:error, "OpenShell CLI not found: #{executable}"}

      resolved ->
        case System.cmd(resolved, ["status"], stderr_to_stdout: true, env: [{"NO_COLOR", "1"}]) do
          {_output, 0} ->
            :ok

          {output, exit_code} ->
            message =
              output
              |> String.trim()
              |> case do
                "" -> "openshell status exited with code #{exit_code}"
                value -> value
              end

            {:error, "OpenShell is not running or not ready: #{message}"}
        end
    end
  rescue
    error in ErlangError ->
      {:error, "failed to invoke OpenShell CLI #{executable}: #{Exception.message(error)}"}
  end

  defp format_reason(%Redix.ConnectionError{} = reason), do: Exception.message(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
