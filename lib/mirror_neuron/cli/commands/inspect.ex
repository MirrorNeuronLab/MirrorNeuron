defmodule MirrorNeuron.CLI.Commands.Inspect do
  alias MirrorNeuron.CLI.Output

  def jobs(args \\ []) do
    {opts, _, _} = OptionParser.parse(args, strict: [live: :boolean, all: :boolean])

    Output.maybe_print_section("List jobs")

    Output.print_result(
      MirrorNeuron.list_jobs(
        include_terminal: true,
        live_only: not Keyword.get(opts, :all, false)
      )
    )
  end

  def job(job_id) do
    Output.maybe_print_section("Job inspect", job_id)
    Output.print_job_result(MirrorNeuron.inspect_job(job_id))
  end

  def agents(job_id) do
    Output.maybe_print_section("Agent list", job_id)
    Output.print_agents_result(MirrorNeuron.inspect_agents(job_id))
  end

  def nodes do
    Output.maybe_print_section("Node list")
    Output.print_nodes(MirrorNeuron.inspect_nodes())
  end

  def events(job_id) do
    Output.maybe_print_section("Inspect events", job_id)
    Output.print_events_result(MirrorNeuron.events(job_id))
  end
end
