defmodule MirrorNeuron.Sandbox.WitNativeSkills do
  @moduledoc "Route a pinned skill import to the native SDK on the invoking executor."
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.ModelServices.Commands
  alias MirrorNeuron.Sandbox.Wasmtime

  def call(record, scope, operation, input, %{skills: skills, executor: executor, access: access}) do
    with [skill, method] <- String.split(operation, "."),
         name = String.replace(skill, "-", "_") <> "_skill",
         true <- name in skills and declared?(record, name),
         {:ok, arguments} when is_map(arguments) <- Jason.decode(input) do
      command = %{
        "kind" => "wit_skill",
        "scope" => scope,
        "run_data_ref" => SharedStorage.run_data_ref(record),
        "job_data_write" => record["job_data_access"] == "read_write" and access == "read_write",
        "skill" => skill,
        "operation" => method,
        "arguments" => arguments
      }

      timeout = :timer.seconds(Wasmtime.max_compute_seconds())

      response =
        if executor == node(),
          do: Commands.job_response_command(command, timeout),
          else:
            :rpc.call(
              executor,
              Commands,
              :job_response_command,
              [command, timeout],
              timeout + 1_000
            )

      case response do
        {:ok, %{"value" => value}} -> Jason.encode(value)
        _ -> {:error, :native_skill_unavailable}
      end
    else
      _ -> {:error, :invalid_native_skill_request}
    end
  end

  defp declared?(record, name) do
    deps = get_in(record, ["manifest", "skill_dependencies"]) || []

    Enum.any?(deps, fn
      %{
        "name" => ^name,
        "source" => source,
        "type" => "wit",
        "version" => "1.0.0",
        "sha256" => digest
      }
      when source in ["skill", "payload"] and is_binary(digest) ->
        Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

      _ ->
        false
    end)
  end
end
