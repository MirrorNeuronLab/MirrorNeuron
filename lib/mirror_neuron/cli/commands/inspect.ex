defmodule MirrorNeuron.CLI.Commands.Inspect do
  alias MirrorNeuron.CLI.Output

  def job(job_id) do
    Output.maybe_print_section("Inspect job", job_id)
    Output.print_job_result(MirrorNeuron.inspect_job(job_id))
  end

  def agents(job_id) do
    Output.maybe_print_section("Inspect agents", job_id)
    Output.print_agents_result(MirrorNeuron.inspect_agents(job_id))
  end

  def nodes do
    Output.maybe_print_section("Inspect nodes")
    Output.print_nodes(MirrorNeuron.inspect_nodes())
  end

  def events(job_id) do
    Output.maybe_print_section("Inspect events", job_id)
    Output.print_events_result(MirrorNeuron.events(job_id))
  end
end
