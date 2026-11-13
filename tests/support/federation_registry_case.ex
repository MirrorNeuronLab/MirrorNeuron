defmodule MirrorNeuron.FederationRegistryCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.FederationRegistryCase
    end
  end

  defmodule NodeAdapterStub do
    def self, do: :mirror_neuron@local
    def list, do: []
    def connect(_node), do: false
    def disconnect(_node), do: true
    def set_cookie(_node, _cookie), do: :ok
    def rpc_call(_node, _module, _function, _args, _timeout), do: {:badrpc, :nodedown}
  end

  defmodule CoordinationStoreStub do
    def fetch_resource_limits, do: {:ok, %{}}

    def coordination_store_status do
      {:ok,
       %{
         "identity" => "store-local",
         "healthy" => true,
         "writable_primary" => true,
         "role" => "master"
       }}
    end
  end

  defmodule ProjectionStoreStub do
    def put_federation_projections(owner_node, kind, summaries) do
      key = {__MODULE__, owner_node, kind}
      existing = :persistent_term.get(key, %{})
      saved = Map.merge(existing, index(kind, summaries))
      :persistent_term.put(key, saved)
      {:ok, Map.values(saved)}
    end

    def replace_federation_projections(owner_node, kind, summaries) do
      saved = index(kind, summaries)
      :persistent_term.put({__MODULE__, owner_node, kind}, saved)
      {:ok, Map.values(saved)}
    end

    def list_federation_projections(owner_node, kind) do
      {:ok,
       {__MODULE__, owner_node, kind}
       |> :persistent_term.get(%{})
       |> Map.values()}
    end

    def fetch_federation_projection(owner_node, kind, resource_id) do
      case :persistent_term.get({__MODULE__, owner_node, kind}, %{})[resource_id] do
        nil -> {:error, :not_found}
        projection -> {:ok, projection}
      end
    end

    def delete_federation_projection(owner_node, kind, resource_id) do
      key = {__MODULE__, owner_node, kind}
      :persistent_term.put(key, Map.delete(:persistent_term.get(key, %{}), resource_id))
      :ok
    end

    def delete_federation_projections(owner_node) do
      Enum.each(["job", "run"], &:persistent_term.erase({__MODULE__, owner_node, &1}))
      :ok
    end

    def clear do
      delete_federation_projections("mirror_neuron@peer")
    end

    defp index(kind, summaries) do
      id_field = if kind == "job", do: "job_id", else: "run_id"
      Map.new(summaries, &{Map.fetch!(&1, id_field), &1})
    end
  end

  defmodule NodeStateStoreStub do
    def persist_node_state(node_name, attrs) do
      state = Map.put(attrs, "node", node_name)
      :persistent_term.put({__MODULE__, node_name}, state)
      {:ok, state}
    end

    def fetch_node_state(node_name) do
      case :persistent_term.get({__MODULE__, node_name}, nil) do
        nil -> {:error, :not_found}
        state -> {:ok, state}
      end
    end

    def list_node_states do
      {:ok,
       ["mirror_neuron@peer"]
       |> Enum.map(&:persistent_term.get({__MODULE__, &1}, nil))
       |> Enum.reject(&is_nil/1)}
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "mn-federation-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("MN_HOME")
    previous_network_only = System.get_env("MN_NETWORK_ONLY")
    previous_adapter = Application.get_env(:mirror_neuron, :cluster_node_adapter)
    previous_store = Application.get_env(:mirror_neuron, :coordination_store)

    previous_projection_store =
      Application.get_env(:mirror_neuron, :federation_projection_store)

    previous_state_store = Application.get_env(:mirror_neuron, :node_state_store)

    System.put_env("MN_HOME", home)
    System.put_env("MN_NETWORK_ONLY", "true")
    Application.put_env(:mirror_neuron, :cluster_node_adapter, NodeAdapterStub)
    Application.put_env(:mirror_neuron, :coordination_store, CoordinationStoreStub)
    Application.put_env(:mirror_neuron, :federation_projection_store, ProjectionStoreStub)
    Application.put_env(:mirror_neuron, :node_state_store, NodeStateStoreStub)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_system_env("MN_HOME", previous_home)
      restore_system_env("MN_NETWORK_ONLY", previous_network_only)
      restore_app_env(:cluster_node_adapter, previous_adapter)
      restore_app_env(:coordination_store, previous_store)
      restore_app_env(:federation_projection_store, previous_projection_store)
      restore_app_env(:node_state_store, previous_state_store)
      :persistent_term.erase({NodeStateStoreStub, "mirror_neuron@peer"})
      ProjectionStoreStub.clear()
    end)

    {:ok, home: home}
  end

  def peer_info do
    %{
      "grpc_host" => "127.0.0.2",
      "grpc_port" => 55_051,
      "scheduling_eligible" => true,
      "coordination_store" => %{
        "identity" => "store-peer",
        "healthy" => true,
        "writable_primary" => true
      },
      "litellm" => %{"host" => "127.0.0.2", "port" => 4_000}
    }
  end

  def restore_system_env(name, nil), do: System.delete_env(name)
  def restore_system_env(name, value), do: System.put_env(name, value)

  def restore_app_env(key, nil), do: Application.delete_env(:mirror_neuron, key)
  def restore_app_env(key, value), do: Application.put_env(:mirror_neuron, key, value)
end
