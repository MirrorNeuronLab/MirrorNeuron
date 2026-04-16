defmodule MirrorNeuron.CLI.Commands.Control do
  alias MirrorNeuron.CLI.Output

  def pause(job_id), do: Output.print_result(MirrorNeuron.pause(job_id))
  def resume(job_id), do: Output.print_result(MirrorNeuron.resume(job_id))
  def cancel(job_id), do: Output.print_result(MirrorNeuron.cancel(job_id))
  def cleanup_jobs, do: Output.print_result(MirrorNeuron.cleanup_jobs())

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
