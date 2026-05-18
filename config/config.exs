import Config

config :logger, level: :warning

config :mirror_neuron,
  supported_recovery_modes: ["auto", "local_restart", "cluster_recover", "manual_recover"],
  reliability_strategy: "auto",
  cluster_health_stable_ms: 10_000,
  reliability_observer_interval_ms: 5_000
