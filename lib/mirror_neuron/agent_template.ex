defmodule MirrorNeuron.AgentTemplate do
  defmacro __using__(_opts) do
    quote do
      @behaviour MirrorNeuron.Agent

      def payload(message), do: MirrorNeuron.Agent.payload(message)
      def type(message), do: MirrorNeuron.Agent.type(message)
      def from(message), do: MirrorNeuron.Agent.from(message)
      def to(message), do: MirrorNeuron.Agent.to(message)
      def headers(message), do: MirrorNeuron.Agent.headers(message)
      def artifacts(message), do: MirrorNeuron.Agent.artifacts(message)
      def stream(message), do: MirrorNeuron.Agent.stream(message)
      def envelope(message), do: MirrorNeuron.Agent.envelope(message)
      def recover(state, _context), do: {:ok, state, []}

      defoverridable recover: 2
    end
  end
end
