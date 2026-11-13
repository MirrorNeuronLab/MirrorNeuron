defmodule MirrorNeuron.RuntimeExecutionCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use MirrorNeuron.RuntimeCase
      import MirrorNeuron.RuntimeFixtures.Helpers
      import MirrorNeuron.RuntimeFixtures.Manifests
    end
  end

  setup do
    keys = [:job_health_check_interval_ms, :agent_heartbeat_interval_ms]
    previous = Map.new(keys, &{&1, Application.get_env(:mirror_neuron, &1)})
    Enum.each(keys, &Application.put_env(:mirror_neuron, &1, 100))

    on_exit(fn ->
      MirrorNeuron.RuntimeFixtures.Helpers.cleanup_runtime_namespace()

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:mirror_neuron, key)
        {key, value} -> Application.put_env(:mirror_neuron, key, value)
      end)
    end)

    :ok
  end
end
