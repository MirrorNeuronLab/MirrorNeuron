defmodule MirrorNeuron.MixProject do
  use Mix.Project

  def project do
    [
      app: :mirror_neuron,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      test_paths: ["tests"],
      escript: [main_module: MirrorNeuron.CLI, name: "mn"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {MirrorNeuron.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:libcluster, "~> 3.5"},
      {:horde, "~> 0.10.0"},
      {:redix, "~> 1.5"},
      {:owl, "~> 0.13"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"}
    ]
  end
end
