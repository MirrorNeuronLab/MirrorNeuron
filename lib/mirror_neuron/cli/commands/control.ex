defmodule MirrorNeuron.CLI.Commands.Control do
  alias MirrorNeuron.CLI.Output

  def pause(job_id), do: Output.print_result(MirrorNeuron.pause(job_id))
  def resume(job_id), do: Output.print_result(MirrorNeuron.resume(job_id))
  def cancel(job_id), do: Output.print_result(MirrorNeuron.cancel(job_id))

  def interactive_cancel do
    case MirrorNeuron.list_jobs(live_only: true) do
      {:ok, []} ->
        Output.print_result({:ok, "No running jobs to cancel."})

      {:ok, jobs} ->
        if not MirrorNeuron.CLI.UI.interactive?() do
          Output.abort("Multiple running jobs found. Please specify a job_id: mn cancel <job_id>")
        end

        MirrorNeuron.CLI.UI.puts(MirrorNeuron.CLI.UI.section("Running Jobs"))

        jobs
        |> Enum.with_index(1)
        |> Enum.each(fn {job, idx} ->
          MirrorNeuron.CLI.UI.puts("  #{idx}) #{job["job_id"]} (status: #{job["status"]})")
        end)

        MirrorNeuron.CLI.UI.puts("")
        input = IO.gets("Enter job number to cancel (or 'q' to quit): ") |> String.trim()

        case Integer.parse(input) do
          {idx, ""} when idx > 0 and idx <= length(jobs) ->
            job = Enum.at(jobs, idx - 1)
            cancel(job["job_id"])

          _ ->
            Output.print_result({:ok, "Cancelled interactive selection."})
        end

      {:error, reason} ->
        Output.abort(reason)
    end
  end

  def cleanup_jobs(args \\ []) do
    {opts, _, _} = OptionParser.parse(args, strict: [all: :boolean])
    Output.print_result(MirrorNeuron.cleanup_jobs(opts))
  end

  def add_node(node_name), do: Output.print_result(MirrorNeuron.add_node(node_name))
  def remove_node(node_name), do: Output.print_result(MirrorNeuron.remove_node(node_name))

  def send_message(job_id, agent_id, message_json) do
    case Jason.decode(message_json) do
      {:ok, payload} ->
        Output.print_result(MirrorNeuron.send_message(job_id, agent_id, payload))

      {:error, error} ->
        Output.abort("invalid JSON payload: #{Exception.message(error)}")
    end
  end
end
