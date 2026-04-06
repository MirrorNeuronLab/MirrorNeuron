defmodule MirrorNeuron.CLI.Commands.Validate do
  alias MirrorNeuron.CLI.Output

  def run(job_path) do
    Output.maybe_print_banner(:validate, job_path)

    job_path
    |> MirrorNeuron.validate_manifest()
    |> Output.print_manifest_validation()
  end
end
