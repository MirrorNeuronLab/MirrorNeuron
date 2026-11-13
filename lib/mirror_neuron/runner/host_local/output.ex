defmodule MirrorNeuron.Runner.HostLocal.Output do
  @moduledoc "Caps captured output and parses structured command results."

  @result_start "__MN_RESULT_START__"
  @result_end "__MN_RESULT_END__"

  def append_output(chunks, bytes, data, max_output_bytes) do
    cond do
      bytes >= max_output_bytes ->
        {chunks, bytes + byte_size(data)}

      bytes + byte_size(data) <= max_output_bytes ->
        {[data | chunks], bytes + byte_size(data)}

      true ->
        remaining = max(max_output_bytes - bytes, 0)
        truncated = binary_part(data, 0, remaining) <> "\n[truncated by host local output cap]"
        {[truncated | chunks], bytes + byte_size(data)}
    end
  end

  def extract_result(output, runner_exit_code, runner_name, workdir) do
    pattern = ~r/#{@result_start}\s*(\{.*?\})\s*#{@result_end}/s

    case Regex.run(pattern, output, capture: :all_but_first) do
      [json_blob] ->
        with {:ok, parsed} <- Jason.decode(json_blob) do
          logs =
            output
            |> String.replace(pattern, "")
            |> String.trim()

          {:ok,
           sanitize_result(%{
             "sandbox_name" => runner_name,
             "remote_dir" => workdir,
             "exit_code" => parsed["exit_code"],
             "runner_exit_code" => runner_exit_code,
             "stdout" => parsed["stdout"],
             "stderr" => parsed["stderr"],
             "logs" => logs,
             "raw_output" => output,
             "runner" => "host_local",
             "node_name" => to_string(Node.self())
           })}
        else
          {:error, error} -> {:error, Exception.message(error)}
        end

      _ ->
        {:ok,
         sanitize_result(%{
           "sandbox_name" => runner_name,
           "remote_dir" => workdir,
           "exit_code" => runner_exit_code,
           "runner_exit_code" => runner_exit_code,
           "stdout" => String.trim(output),
           "stderr" => "",
           "logs" => String.trim(output),
           "raw_output" => output,
           "runner" => "host_local",
           "node_name" => to_string(Node.self())
         })}
    end
  end

  defp sanitize_result(result) do
    MirrorNeuron.Runner.Result.sanitize(result)
  end
end
