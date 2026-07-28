defmodule MirrorNeuron.Grpc.Handlers.ClusterHandshake do
  @moduledoc false

  @interface_version 1

  alias MirrorNeuron.Cluster.JoinClaim
  alias MirrorNeuron.Cluster.NodeAdapter
  alias MirrorNeuron.Grpc.Handlers.Support
  alias MirrorNeuron.ModelServices
  alias Mirrorneuron.Cluster.V1.NetworkHandshakeResponse

  def network_handshake(request, stream) do
    authorize_network_join!(Map.get(request, :token, ""))

    if MirrorNeuron.Grpc.NetworkOnly.enabled?() do
      reserve_join_claim!(request, stream)
    else
      maybe_record_joining_node(request)
    end

    %NetworkHandshakeResponse{
      node_name: to_string(NodeAdapter.self()),
      runtime_mode:
        if(MirrorNeuron.Grpc.NetworkOnly.enabled?(), do: "network_only", else: "full"),
      grpc_host: advertised_host(),
      grpc_port: advertised_grpc_port(),
      dist_port: env_integer("MN_DIST_PORT", 4_370),
      redis_host: redis_host(),
      redis_port: redis_port(),
      redis_url: redis_url(),
      cluster_nodes: MirrorNeuron.Config.string("MN_CLUSTER_NODES", :cluster_nodes),
      network_only: MirrorNeuron.Grpc.NetworkOnly.enabled?(),
      node_info_json: Support.versioned_json(handshake_node_info()),
      grpc_auth_token: MirrorNeuron.Grpc.Tokens.auth_token(),
      version: @interface_version
    }
  end

  @doc false
  def node_advertisement_info do
    handshake_node_info()
  end

  defp maybe_record_joining_node(request) do
    node_name = request |> Map.get(:node_name, "") |> to_string() |> String.trim()

    if node_name != "" do
      attrs =
        request
        |> Map.get(:node_info_json, "")
        |> decode_node_info()
        |> Map.put("operator_disconnect", false)
        |> Map.put("scheduling_eligible", true)

      MirrorNeuron.Cluster.NodeState.mark(node_name, handshake_node_status(node_name), attrs)
    end

    :ok
  end

  defp reserve_join_claim!(request, stream) do
    owner = join_claim_owner(request, stream)
    owner_info = request |> Map.get(:node_info_json, "") |> decode_node_info()

    attrs =
      %{
        "owner_peer" => peer_identity(stream),
        "owner_grpc_host" => Map.get(owner_info, "grpc_host"),
        "owner_grpc_port" => Map.get(owner_info, "grpc_port")
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case JoinClaim.reserve(owner, attrs) do
      {:ok, _claim} ->
        :ok

      {:error, :missing_owner} ->
        raise GRPC.RPCError,
          status: GRPC.Status.invalid_argument(),
          message: "joining node_name is required"

      {:error, {:already_joined, _existing_owner}} ->
        raise GRPC.RPCError,
          status: GRPC.Status.already_exists(),
          message: "already join a cluster"

      {:error, reason} ->
        raise GRPC.RPCError,
          status: GRPC.Status.internal(),
          message: "failed to record join claim: #{inspect(reason)}"
    end
  end

  defp join_claim_owner(request, stream) do
    [
      Map.get(request, :node_name, ""),
      request |> Map.get(:node_info_json, "") |> decode_node_info() |> Map.get("node_name"),
      peer_identity(stream)
    ]
    |> Enum.find_value(fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when not is_nil(value) ->
        value |> to_string() |> String.trim() |> Support.blank_to_nil()

      _value ->
        nil
    end)
  end

  defp peer_identity(%{adapter: adapter, payload: payload})
       when is_atom(adapter) and not is_nil(payload) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :get_peer, 1) do
      case adapter.get_peer(payload) do
        {address, port} -> "peer:#{format_address(address)}:#{port}"
        address -> "peer:#{format_address(address)}"
      end
    end
  rescue
    _ -> nil
  end

  defp peer_identity(_stream), do: nil

  defp format_address(address) when is_tuple(address), do: address |> :inet.ntoa() |> to_string()
  defp format_address(address), do: to_string(address)

  defp handshake_node_status(node_name) do
    case MirrorNeuron.Cluster.NodeState.fetch(node_name) do
      {:ok, %{"status" => status}} when status in ["healthy", "maintenance", "draining"] ->
        status

      _ ->
        "joining"
    end
  end

  defp decode_node_info(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> value
      _ -> %{}
    end
  end

  defp decode_node_info(_json), do: %{}

  defp handshake_node_info do
    hardware = MirrorNeuron.Cluster.Hardware.info()
    platform = Map.get(hardware, :platform, %{})
    cpu = Map.get(hardware, :cpu, %{})
    memory = Map.get(hardware, :memory, %{})
    gpu = Map.get(hardware, :gpu)

    %{
      "node_name" => to_string(NodeAdapter.self()),
      "node_role" => MirrorNeuron.Application.node_role(),
      "grpc_host" => advertised_host(),
      "grpc_port" => advertised_grpc_port(),
      "host_shared_storage_root" =>
        MirrorNeuron.Config.optional_string(
          "MN_HOST_SHARED_STORAGE_ROOT",
          :host_shared_storage_root
        ),
      "runtime_shared_storage_root" =>
        MirrorNeuron.Config.string("MN_RUNTIME_SHARED_STORAGE_ROOT", :runtime_shared_storage_root),
      "syncthing" => syncthing_node_info(),
      "redis_ha" => redis_ha_node_info(),
      "coordination_store" => coordination_store_node_info(),
      "native_sdk_grpc" => native_sdk_grpc_node_info(hardware),
      "display_name" => map_value(platform, "display_name"),
      "hostname" => map_value(platform, "hostname"),
      "cpu_cores" => map_value(cpu, "logical_processors"),
      "cpu_model" => map_value(cpu, "model"),
      "gpu_count" => gpu_count(gpu),
      "gpu_model" => List.first(gpu_models(gpu)),
      "gpu_models" => gpu_models(gpu),
      "memory_gb" => memory_gb(memory),
      "runtime_models" => ModelServices.env_model_refs(),
      "services" => ModelServices.service_instances_for_env(System.get_env(), NodeAdapter.self())
    }
  end

  defp coordination_store_node_info do
    case MirrorNeuron.Persistence.RedisStore.coordination_store_status() do
      {:ok, status} ->
        status

      {:error, reason} ->
        %{
          "identity" => "",
          "role" => "unknown",
          "writable_primary" => false,
          "healthy" => false,
          "error" => inspect(reason)
        }
    end
  end

  defp redis_ha_node_info do
    %{
      "mode" => MirrorNeuron.Config.string("MN_REDIS_HA_MODE", :redis_ha_mode),
      "sentinels" => MirrorNeuron.Config.string("MN_REDIS_SENTINELS", :redis_sentinels),
      "sentinel_master" =>
        MirrorNeuron.Config.string("MN_REDIS_SENTINEL_MASTER", :redis_sentinel_master),
      "sentinel_host_map" =>
        MirrorNeuron.Config.string("MN_REDIS_SENTINEL_HOST_MAP", :redis_sentinel_host_map),
      "db" => MirrorNeuron.Config.integer("MN_REDIS_DB", :redis_db),
      "sentinel_port" =>
        MirrorNeuron.Config.integer("MN_REDIS_SENTINEL_PORT", :redis_sentinel_port),
      "wait_replicas" =>
        MirrorNeuron.Config.integer("MN_REDIS_WAIT_REPLICAS", :redis_wait_replicas),
      "wait_timeout_ms" =>
        MirrorNeuron.Config.integer("MN_REDIS_WAIT_TIMEOUT_MS", :redis_wait_timeout_ms),
      "reconnect_attempts" =>
        MirrorNeuron.Config.integer("MN_REDIS_RECONNECT_ATTEMPTS", :redis_reconnect_attempts),
      "reconnect_backoff_ms" =>
        MirrorNeuron.Config.integer("MN_REDIS_RECONNECT_BACKOFF_MS", :redis_reconnect_backoff_ms),
      "reconnect_max_backoff_ms" =>
        MirrorNeuron.Config.integer(
          "MN_REDIS_RECONNECT_MAX_BACKOFF_MS",
          :redis_reconnect_max_backoff_ms
        )
    }
  end

  defp syncthing_node_info do
    enabled =
      MirrorNeuron.Config.string("MN_SYNCTHING_ENABLED", :syncthing_enabled)
      |> String.trim()
      |> String.downcase()

    %{
      "enabled" => enabled not in ["", "0", "false", "no", "n", "off", "disabled"],
      "device_id" => MirrorNeuron.Config.string("MN_SYNCTHING_DEVICE_ID", :syncthing_device_id),
      "api_key" => MirrorNeuron.Config.string("MN_SYNCTHING_API_KEY", :syncthing_api_key),
      "host" =>
        MirrorNeuron.Config.string("MN_SYNCTHING_ADVERTISE_HOST", :syncthing_advertise_host),
      "gui_port" => MirrorNeuron.Config.integer("MN_SYNCTHING_GUI_PORT", :syncthing_gui_port),
      "sync_port" => MirrorNeuron.Config.integer("MN_SYNCTHING_SYNC_PORT", :syncthing_sync_port),
      "rescan_interval_seconds" =>
        MirrorNeuron.Config.integer(
          "MN_SYNCTHING_RESCAN_INTERVAL_SECONDS",
          :syncthing_rescan_interval_seconds
        ),
      "folder_id" => MirrorNeuron.Config.string("MN_SYNCTHING_FOLDER_ID", :syncthing_folder_id),
      "folder_path" =>
        MirrorNeuron.Config.string("MN_SYNCTHING_FOLDER_PATH", :syncthing_folder_path)
    }
  end

  defp map_value(map, key) when is_map(map), do: MirrorNeuron.SafeAccess.map_get(map, key)

  defp map_value(_map, _key), do: nil

  defp gpu_count(gpu) when is_list(gpu), do: length(gpu)
  defp gpu_count(%{} = gpu), do: map_value(gpu, "count") || 0
  defp gpu_count(_gpu), do: 0

  defp gpu_models(gpus) when is_list(gpus) do
    gpus
    |> Enum.map(fn
      gpu when is_map(gpu) -> map_value(gpu, "model") || map_value(gpu, "name")
      gpu when is_binary(gpu) -> gpu
      _gpu -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or unknown_gpu?(&1)))
    |> Enum.uniq()
  end

  defp gpu_models(%{} = gpu), do: gpu_models([gpu])
  defp gpu_models(gpu) when is_binary(gpu), do: if(unknown_gpu?(gpu), do: [], else: [gpu])
  defp gpu_models(_gpu), do: []

  defp unknown_gpu?(gpu) do
    normalized = String.downcase(to_string(gpu || ""))

    Enum.any?(["unknown", "none", "unsupported", "not available"], fn marker ->
      String.contains?(normalized, marker)
    end)
  end

  defp memory_gb(memory) do
    case map_value(memory, "total_mb") do
      value when is_number(value) -> Float.round(value / 1024, 2)
      _ -> 0
    end
  end

  defp authorize_network_join!(request_token) do
    expected_token =
      "MN_NETWORK_JOIN_TOKEN"
      |> MirrorNeuron.Config.secret(:network_join_token)
      |> to_string()
      |> String.trim()

    request_token = to_string(request_token || "") |> String.trim()

    unless expected_token != "" and secure_compare(request_token, expected_token) do
      raise GRPC.RPCError,
        status: GRPC.Status.unauthenticated(),
        message: "valid MN_NETWORK_JOIN_TOKEN is required"
    end

    :ok
  end

  defp secure_compare(left, right), do: MirrorNeuron.Grpc.Tokens.secure_compare(left, right)

  defp advertised_host do
    MirrorNeuron.Config.optional_string("MN_NETWORK_ADVERTISE_HOST", :network_advertise_host) ||
      MirrorNeuron.Config.string("MN_CORE_HOST", :core_host)
  end

  defp advertised_grpc_port do
    case System.get_env("MN_GRPC_ADVERTISE_PORT") do
      nil -> env_integer("MN_GRPC_PORT", 50_051)
      "" -> env_integer("MN_GRPC_PORT", 50_051)
      value -> parse_integer(value, "MN_GRPC_ADVERTISE_PORT")
    end
  end

  defp native_sdk_grpc_node_info(hardware) do
    host =
      System.get_env("MN_NATIVE_SDK_GRPC_ADVERTISE_HOST") ||
        MirrorNeuron.Config.optional_string("MN_NETWORK_ADVERTISE_HOST", :network_advertise_host) ||
        advertised_host()

    port = native_sdk_grpc_port()
    target = if host in [nil, ""], do: "", else: "#{host}:#{port}"

    advertised = map_value(hardware, "native_sdk_grpc") || %{}

    %{
      "enabled" => host not in [nil, ""] and port not in [nil, ""],
      "host" => host || "",
      "port" => port,
      "target" => target,
      "bind_host" => System.get_env("MN_NATIVE_SDK_GRPC_HOST") || "",
      "capabilities" => map_value(advertised, "capabilities") || []
    }
  end

  defp native_sdk_grpc_port do
    case System.get_env("MN_NATIVE_SDK_GRPC_ADVERTISE_PORT") do
      nil -> System.get_env("MN_NATIVE_SDK_GRPC_PORT") || "55052"
      "" -> System.get_env("MN_NATIVE_SDK_GRPC_PORT") || "55052"
      value -> value
    end
  end

  defp redis_host do
    MirrorNeuron.Config.optional_string("MN_NETWORK_REDIS_HOST", :network_redis_host) ||
      (redis_uri().host || advertised_host())
  end

  defp redis_port do
    case MirrorNeuron.Config.optional_string("MN_NETWORK_REDIS_PORT", :network_redis_port) do
      nil -> redis_uri().port || 6_379
      value -> parse_integer(value, "MN_NETWORK_REDIS_PORT")
    end
  end

  defp redis_url do
    uri = redis_uri()
    host = redis_host()
    port = redis_port()
    path = uri.path || "/0"
    scheme = uri.scheme || "redis"
    userinfo = if uri.userinfo in [nil, ""], do: "", else: "#{uri.userinfo}@"

    "#{scheme}://#{userinfo}#{host}:#{port}#{path}"
  end

  defp redis_uri do
    MirrorNeuron.Redis.connection_url()
    |> URI.parse()
  end

  defp env_integer(name, default) do
    case MirrorNeuron.Config.optional_string(name, env_key(name)) do
      nil -> default
      value -> parse_integer(value, name)
    end
  end

  defp parse_integer(value, name) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> raise ArgumentError, "#{name} must be an integer, got #{inspect(value)}"
    end
  end

  defp env_key("MN_GRPC_PORT"), do: :grpc_port
  defp env_key("MN_DIST_PORT"), do: :dist_port
end
