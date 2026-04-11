import Config

config :mirror_neuron,
  redis_url: System.get_env("MIRROR_NEURON_REDIS_URL", "redis://127.0.0.1:6379/0"),
  redis_namespace: System.get_env("MIRROR_NEURON_REDIS_NAMESPACE", "mirror_neuron"),
  cookie: System.get_env("MIRROR_NEURON_COOKIE", "mirrorneuron"),
  openshell_bin: System.get_env("MIRROR_NEURON_OPENSHELL_BIN", "openshell"),
  temp_dir: System.get_env("MIRROR_NEURON_TEMP_DIR", "/tmp/mirror_neuron"),
  api_port: String.to_integer(System.get_env("MIRROR_NEURON_API_PORT", "4000")),
  api_enabled:
    System.get_env("MIRROR_NEURON_API_ENABLED", "true") not in [
      "0",
      "false",
      "FALSE",
      "False",
      ""
    ]
