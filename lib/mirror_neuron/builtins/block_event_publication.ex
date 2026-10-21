defmodule MirrorNeuron.Builtins.BlockEventPublication do
  @moduledoc false

  # Called only after BlockEventResult accepts the current state transition.
  # A failed copy leaves the prior state intact; the same event result can replay.
  def publish(payload, config, context) do
    if Map.has_key?(payload, "publication") do
      do_publish(payload, config, context)
    else
      {:ok, []}
    end
  end

  defp do_publish(payload, config, context) do
    environment = config["environment"] || %{}
    submission = environment["MN_JOB_SHARED_STORAGE_ROOT"]
    run_id = get_in(context, [:workflow, "run_id"])
    trusted = MirrorNeuron.Config.string("MN_SHARED_STORAGE_ROOT", :shared_storage_root)

    if is_binary(submission) and is_binary(trusted) and is_binary(run_id) and
         Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,255}$/, run_id) do
      request = %{
        "run_dir" => Path.join([submission, "outputs", "runs", run_id]),
        "output_dir" => output_directory(config, environment),
        "trusted_root" => trusted,
        "publication" => payload["publication"],
        "handoff" => get_in(payload, ["event_result", "handoff"])
      }

      invoke(request)
    else
      error("event publication requires owner storage and the physical run identity", false)
    end
  end

  defp output_directory(%{"artifact_handoff" => policy}, environment) when is_map(policy) do
    if policy["export_outputs"] == true, do: environment["MN_JOB_OUTPUT_DIR"], else: nil
  end

  defp output_directory(_, environment), do: environment["MN_JOB_OUTPUT_DIR"]

  defp invoke(request) do
    path =
      Path.join(
        System.tmp_dir!(),
        "mn-event-publication-#{System.unique_integer([:positive])}.json"
      )

    try do
      File.write!(path, Jason.encode!(request))
      script = Application.app_dir(:mirror_neuron, "priv/openshell_handoff/published_files.py")

      case System.cmd("python3", [script, path], stderr_to_stdout: true) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, %{"ok" => %{"warnings" => warnings}}} when is_list(warnings) -> {:ok, warnings}
            _ -> error("invalid event publication response", false)
          end

        {output, _} ->
          case Jason.decode(output) do
            {:ok, %{"kind" => kind}} ->
              error("event publication failed: #{kind}", kind == "OSError")

            _ ->
              error("event publication helper unavailable", true)
          end
      end
    rescue
      _ -> error("event publication helper unavailable", true)
    after
      File.rm(path)
    end
  end

  defp error(message, retryable), do: {:error, %{"error" => message, "retryable" => retryable}}
end
