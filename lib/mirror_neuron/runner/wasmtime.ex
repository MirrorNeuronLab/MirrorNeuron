defmodule MirrorNeuron.Runner.Wasmtime do
  @moduledoc "Executes a bundled WASI 0.3 command under the run admission fence."
  @behaviour MirrorNeuron.Runner

  @impl true
  defdelegate run(payload, config, opts), to: MirrorNeuron.Sandbox.Wasmtime

  @impl true
  defdelegate stop_commands(job_id, agents),
    to: MirrorNeuron.Runner.HostLocal.Ownership,
    as: :terminate_agents
end
