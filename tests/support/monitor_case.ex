defmodule MirrorNeuron.MonitorCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.MonitorCase
    end
  end

  setup do
    Application.ensure_all_started(:mirror_neuron)
    old_namespace_env = System.get_env("MN_REDIS_NAMESPACE")
    old_namespace = Application.get_env(:mirror_neuron, :redis_namespace)
    namespace = "mirror_neuron_test_#{System.unique_integer([:positive])}"
    System.put_env("MN_REDIS_NAMESPACE", namespace)
    Application.put_env(:mirror_neuron, :redis_namespace, namespace)

    on_exit(fn ->
      case old_namespace_env do
        nil -> System.delete_env("MN_REDIS_NAMESPACE")
        value -> System.put_env("MN_REDIS_NAMESPACE", value)
      end

      Application.put_env(:mirror_neuron, :redis_namespace, old_namespace)
    end)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> raise "Redis must be running for monitor tests"
    end
  end
end
