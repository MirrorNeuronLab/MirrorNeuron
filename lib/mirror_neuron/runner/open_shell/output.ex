defmodule MirrorNeuron.Runner.OpenShell.Output do
  @moduledoc "Parses worker results while distinguishing command failure from cleanup warnings."

  @result_start "__MN_RESULT_START__"
  @result_end "__MN_RESULT_END__"

  def extract_result(output, sandbox_name, remote_dir, openshell_exit_code) do
    pattern = ~r/#{@result_start}\s*(\{.*?\})\s*#{@result_end}/s

    case Regex.run(pattern, output, capture: :all_but_first) do
      [json_blob] ->
        with {:ok, parsed} <- Jason.decode(json_blob) do
          logs =
            output
            |> String.replace(pattern, "")
            |> String.trim()

          {:ok,
           %{
             "sandbox_name" => sandbox_name,
             "remote_dir" => remote_dir,
             "exit_code" => parsed["exit_code"],
             "openshell_exit_code" => openshell_exit_code,
             "stdout" => parsed["stdout"],
             "stderr" => parsed["stderr"],
             "logs" => logs,
             "raw_output" => output
           }
           |> sanitize_result()
           |> maybe_put_cleanup_warning(parsed["exit_code"], openshell_exit_code, logs)}
        else
          {:error, error} -> {:error, Exception.message(error)}
        end

      _ ->
        {:ok,
         %{
           "sandbox_name" => sandbox_name,
           "remote_dir" => remote_dir,
           "exit_code" => openshell_exit_code,
           "openshell_exit_code" => openshell_exit_code,
           "stdout" => "",
           "stderr" => "",
           "logs" => String.trim(output),
           "raw_output" => output
         }
         |> sanitize_result()
         |> maybe_put_cleanup_warning(
           openshell_exit_code,
           openshell_exit_code,
           String.trim(output)
         )}
    end
  end

  defp sanitize_result(result) do
    MirrorNeuron.Runner.Result.sanitize(result)
  end

  defp maybe_put_cleanup_warning(result, worker_exit_code, openshell_exit_code, logs) do
    if worker_exit_code == 0 and openshell_exit_code != 0 do
      result
      |> Map.put(
        "warning",
        "worker command succeeded but OpenShell exited with #{openshell_exit_code} during sandbox cleanup"
      )
      |> Map.put("cleanup_logs", logs)
    else
      result
    end
  end
end
