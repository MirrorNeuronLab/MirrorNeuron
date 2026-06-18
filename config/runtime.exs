import Config

redis_host = System.get_env("MN_REDIS_HOST", "localhost")

positive_integer = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} when parsed > 0 -> parsed
        _ -> default
      end
  end
end

nonnegative_integer = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} when parsed >= 0 -> parsed
        _ -> default
      end
  end
end

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

blob_store_root =
  System.get_env("MN_BLOB_STORE_ROOT", Path.join(System.user_home!(), ".mn/blobs"))

job_artifact_root =
  System.get_env(
    "MN_JOB_ARTIFACT_ROOT",
    blob_store_root |> Path.expand() |> Path.dirname() |> Path.join("jobs")
  )

shared_storage_root =
  System.get_env("MN_RUNTIME_SHARED_STORAGE_ROOT") ||
    System.get_env("MN_SHARED_STORAGE_ROOT") ||
    Path.join(System.user_home!(), ".mn/shared")

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
  recovery_eval_ttl_seconds: positive_integer.("MN_RECOVERY_EVAL_TTL_SECONDS", 86_400),
  job_lease_duration_ms: positive_integer.("MN_JOB_LEASE_DURATION_MS", 60_000),
  job_lease_renew_interval_ms: positive_integer.("MN_JOB_LEASE_RENEW_INTERVAL_MS", 10_000),
  job_call_timeout_ms: positive_integer.("MN_JOB_CALL_TIMEOUT_MS", 15_000),
  delivery_retry_attempts: nonnegative_integer.("MN_DELIVERY_RETRY_ATTEMPTS", 50),
  delivery_retry_interval_ms: nonnegative_integer.("MN_DELIVERY_RETRY_INTERVAL_MS", 50),
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
  blob_store_root: blob_store_root,
  job_artifact_root: job_artifact_root,
  shared_storage_root: shared_storage_root,
  resource_admission_enabled:
    System.get_env("MN_RESOURCE_ADMISSION_ENABLED", "true") not in [
      "0",
      "false",
      "FALSE",
      "False",
      ""
    ],
  grpc_port: String.to_integer(System.get_env("MN_GRPC_PORT", "50051"))
