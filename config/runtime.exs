import Config

redis_host = System.get_env("MN_REDIS_HOST", "localhost")

execution_profiles =
  case System.get_env("MN_EXECUTION_PROFILES_JSON", "") do
    "" ->
      %{}

    raw ->
      case Jason.decode(raw) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> %{}
      end
  end

config :mirror_neuron,
  redis_url: System.get_env("MN_REDIS_URL", "redis://#{redis_host}:6379/0"),
  redis_namespace: System.get_env("MN_REDIS_NAMESPACE", "mirror_neuron"),
  redis_ha_mode: System.get_env("MN_REDIS_HA_MODE", "single"),
  redis_sentinels: System.get_env("MN_REDIS_SENTINELS", ""),
  redis_sentinel_master: System.get_env("MN_REDIS_SENTINEL_MASTER", "mirror-neuron"),
  redis_sentinel_host_map: System.get_env("MN_REDIS_SENTINEL_HOST_MAP", ""),
  redis_db: String.to_integer(System.get_env("MN_REDIS_DB", "0")),
  redis_username: System.get_env("MN_REDIS_USERNAME"),
  redis_password: System.get_env("MN_REDIS_PASSWORD"),
  redis_sentinel_username: System.get_env("MN_REDIS_SENTINEL_USERNAME"),
  redis_sentinel_password: System.get_env("MN_REDIS_SENTINEL_PASSWORD"),
  redis_wait_replicas: String.to_integer(System.get_env("MN_REDIS_WAIT_REPLICAS", "0")),
  redis_wait_timeout_ms: String.to_integer(System.get_env("MN_REDIS_WAIT_TIMEOUT_MS", "100")),
  redis_reconnect_attempts:
    String.to_integer(System.get_env("MN_REDIS_RECONNECT_ATTEMPTS", "10")),
  redis_reconnect_backoff_ms:
    String.to_integer(System.get_env("MN_REDIS_RECONNECT_BACKOFF_MS", "250")),
  redis_reconnect_max_backoff_ms:
    String.to_integer(System.get_env("MN_REDIS_RECONNECT_MAX_BACKOFF_MS", "2000")),
  reliability_strategy: System.get_env("MN_RELIABILITY_STRATEGY", "auto"),
  cluster_health_stable_ms:
    String.to_integer(System.get_env("MN_CLUSTER_HEALTH_STABLE_MS", "10000")),
  reliability_observer_interval_ms:
    String.to_integer(System.get_env("MN_RELIABILITY_OBSERVER_INTERVAL_MS", "5000")),
  node_reconnect_attempts: String.to_integer(System.get_env("MN_NODE_RECONNECT_ATTEMPTS", "3")),
  node_reconnect_backoff_ms:
    String.to_integer(System.get_env("MN_NODE_RECONNECT_BACKOFF_MS", "1000")),
  execution_profiles: execution_profiles,
  cookie: System.get_env("MN_COOKIE", "mirrorneuron"),
  openshell_bin: System.get_env("MN_OPENSHELL_BIN", "openshell"),
  temp_dir: System.get_env("MN_TEMP_DIR", "/tmp/mirror_neuron"),
  blob_store_root:
    System.get_env("MN_BLOB_STORE_ROOT", Path.join(System.user_home!(), ".mn/blobs")),
  artifact_enabled:
    System.get_env("MN_ARTIFACT_ENABLED", "true") not in [
      "0",
      "false",
      "FALSE",
      "False",
      ""
    ],
  artifact_bind_host: System.get_env("MN_ARTIFACT_BIND_HOST", "0.0.0.0"),
  artifact_port: String.to_integer(System.get_env("MN_ARTIFACT_PORT", "55660")),
  artifact_advertise_url: System.get_env("MN_ARTIFACT_ADVERTISE_URL"),
  resource_admission_enabled:
    System.get_env("MN_RESOURCE_ADMISSION_ENABLED", "true") not in [
      "0",
      "false",
      "FALSE",
      "False",
      ""
    ],
  api_port: String.to_integer(System.get_env("MN_API_PORT", "4000")),
  api_enabled:
    System.get_env("MN_API_ENABLED", "true") not in [
      "0",
      "false",
      "FALSE",
      "False",
      ""
    ]
