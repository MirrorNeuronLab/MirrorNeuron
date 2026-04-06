import Config

config :logger, level: :warning

config :mirror_neuron,
  supported_recovery_modes: ["local_restart", "cluster_recover", "manual_recover"]
