defmodule MirrorNeuron.Runner.CoreEnvironment do
  @moduledoc false

  # These are execution-node values, never credentials from a saved definition.
  def docker_worker(environment, runtime_environment, auth_token) do
    port =
      present(runtime_environment["MN_GRPC_ADVERTISE_PORT"]) ||
        present(runtime_environment["MN_GRPC_PORT"]) || "55051"

    target =
      present(runtime_environment["MN_RUNTIME_MODEL_CONTROL_TARGET"]) ||
        "host.docker.internal:#{port}"

    environment
    |> Map.drop(~w(MN_AUTH_TOKEN MN_GRPC_ADMIN_TOKEN MN_RUNTIME_CONTROL_TOKEN))
    |> Map.merge(%{
      "MN_GRPC_TARGET" => target,
      "MN_RUNTIME_MODEL_CONTROL_TARGET" => target,
      "MN_GRPC_AUTH_TOKEN" => to_string(auth_token || "")
    })
  end

  defp present(nil), do: nil

  defp present(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end
end
