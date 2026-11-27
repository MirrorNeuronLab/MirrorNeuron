defmodule MirrorNeuron.Sandbox.WitNativeSkills do
  @moduledoc "Route a selected, pinned WIT component import to the invoking executor's native SDK."
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.ModelServices.Commands
  alias MirrorNeuron.Sandbox.Wasmtime

  def call(record, scope, operation, input, %{skills: skills, executor: executor, access: access}) do
    with [skill, method] <- String.split(operation, "."),
         true <- declared?(record, skills, skill),
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

  defp declared?(record, selected, interface) do
    deps = get_in(record, ["manifest", "skill_dependencies"]) || []
    base = String.replace(interface, "-", "_")
    skill_name = base <> "_skill"
    package_name = "mn_sdk_" <> base

    Enum.any?(deps, fn
      %{
        "name" => name,
        "source" => source,
        "type" => "wit",
        "version" => "1.0.0",
        "sha256" => digest
      }
      when source in ["skill", "payload"] and is_binary(digest) ->
        name in selected and
          (name == skill_name or (source == "payload" and name == package_name)) and
          Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

      _ ->
        false
    end)
  end
end
