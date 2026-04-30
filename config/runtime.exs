import Config

redis_host = System.get_env("MIRROR_NEURON_REDIS_HOST", "localhost")

config :mirror_neuron,
  redis_url: System.get_env("MIRROR_NEURON_REDIS_URL", "redis://#{redis_host}:6379/0"),
  redis_namespace: System.get_env("MIRROR_NEURON_REDIS_NAMESPACE", "mirror_neuron"),
  redis_ha_mode: System.get_env("MIRROR_NEURON_REDIS_HA_MODE", "single"),
  redis_sentinels: System.get_env("MIRROR_NEURON_REDIS_SENTINELS", ""),
  redis_sentinel_master: System.get_env("MIRROR_NEURON_REDIS_SENTINEL_MASTER", "mirror-neuron"),
  redis_sentinel_host_map: System.get_env("MIRROR_NEURON_REDIS_SENTINEL_HOST_MAP", ""),
  redis_db: String.to_integer(System.get_env("MIRROR_NEURON_REDIS_DB", "0")),
  redis_username: System.get_env("MIRROR_NEURON_REDIS_USERNAME"),
  redis_password: System.get_env("MIRROR_NEURON_REDIS_PASSWORD"),
  redis_sentinel_username: System.get_env("MIRROR_NEURON_REDIS_SENTINEL_USERNAME"),
  redis_sentinel_password: System.get_env("MIRROR_NEURON_REDIS_SENTINEL_PASSWORD"),
  redis_wait_replicas:
    String.to_integer(System.get_env("MIRROR_NEURON_REDIS_WAIT_REPLICAS", "0")),
  redis_wait_timeout_ms:
    String.to_integer(System.get_env("MIRROR_NEURON_REDIS_WAIT_TIMEOUT_MS", "100")),
  redis_reconnect_attempts:
    String.to_integer(System.get_env("MIRROR_NEURON_REDIS_RECONNECT_ATTEMPTS", "10")),
  redis_reconnect_backoff_ms:
    String.to_integer(System.get_env("MIRROR_NEURON_REDIS_RECONNECT_BACKOFF_MS", "250")),
  redis_reconnect_max_backoff_ms:
    String.to_integer(System.get_env("MIRROR_NEURON_REDIS_RECONNECT_MAX_BACKOFF_MS", "2000")),
  cookie: System.get_env("MIRROR_NEURON_COOKIE", "mirrorneuron"),
  openshell_bin: System.get_env("MIRROR_NEURON_OPENSHELL_BIN", "openshell"),
  temp_dir: System.get_env("MIRROR_NEURON_TEMP_DIR", "/tmp/mirror_neuron"),
  resource_admission_enabled:
    System.get_env("MIRROR_NEURON_RESOURCE_ADMISSION_ENABLED", "true") not in [
      "0",
      "false",
      "FALSE",
      "False",
      ""
    ],
  api_port: String.to_integer(System.get_env("MIRROR_NEURON_API_PORT", "4000")),
  api_enabled:
    System.get_env("MIRROR_NEURON_API_ENABLED", "true") not in [
      "0",
      "false",
      "FALSE",
      "False",
      ""
    ]
