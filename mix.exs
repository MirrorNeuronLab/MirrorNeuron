defmodule MirrorNeuron.MixProject do
  use Mix.Project

  def project do
    [
      app: :mirror_neuron,
      version: project_version(),
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      test_paths: ["tests"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {MirrorNeuron.Application, []}
    ]
  end

  defp project_version do
    System.get_env("MIX_PROJECT_VERSION", "0.1.0")
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:libcluster, "~> 3.5"},
      {:horde, "~> 0.10.0"},
      {:redix, "~> 1.5"},
      {:grpc, "~> 0.9.0"},
      {:protobuf, "~> 0.16.0"}
    ]
  end
end
