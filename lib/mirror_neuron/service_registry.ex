defmodule MirrorNeuron.ServiceRegistry do
  @moduledoc false

  alias MirrorNeuron.Persistence.RedisStore
  alias MirrorNeuron.ServiceSpec

  def register(service) when is_map(service) do
    service =
      service
      |> stringify_map()
      |> Map.put_new("provider", "mirror_neuron")
      |> Map.put_new("origin", "internal")
      |> Map.put_new("status", "passing")

    service =
      Map.put_new(service, "health", %{
        "status" => Map.get(service, "status", "passing"),
        "checks" => []
      })

    RedisStore.persist_service_instance(Map.fetch!(service, "id"), service)
  end

  def register_many(services) when is_list(services) do
    services
    |> Enum.reduce_while({:ok, []}, fn service, {:ok, acc} ->
      case register(service) do
        {:ok, registered} -> {:cont, {:ok, [registered | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, registered} -> {:ok, Enum.reverse(registered)}
      error -> error
    end
  end

  def list(opts \\ []) do
    with {:ok, services} <- RedisStore.list_service_instances(opts) do
      {:ok, filter_services(services, opts)}
    end
  end

  def resolve(name, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:passing_only, true)

    list(opts)
  end

  def update_health(service_id, health) do
    with {:ok, service} <- RedisStore.fetch_service_instance(service_id) do
      status = Map.get(health, "status") || Map.get(health, :status) || "critical"

      service
      |> Map.put("status", status)
      |> Map.put("health", stringify_map(health))
      |> Map.put("last_check_at", timestamp())
      |> register()
    end
  end

  def deregister_service(service_id), do: RedisStore.delete_service_instance(service_id)
  def deregister_job(job_id), do: RedisStore.delete_service_instances(job_id: job_id)

  def deregister_agent(job_id, agent_id),
    do: RedisStore.delete_service_instances(job_id: job_id, agent_id: agent_id)

  def requirements_satisfied_on_node?(requirements, node_name, opts \\ []) do
    requirements
    |> List.wrap()
    |> Enum.all?(fn requirement ->
      requirement = stringify_map(requirement)

      if ServiceSpec.required?(requirement) do
        requirement_satisfied_on_node?(requirement, node_name, opts)
      else
        true
      end
    end)
  end

  defp requirement_satisfied_on_node?(requirement, node_name, opts) do
    services = Keyword.get(opts, :service_instances)

    result =
      if is_list(services) do
        {:ok, services}
      else
        list(node: node_name, passing_only: true)
      end

    case result do
      {:ok, services} ->
        Enum.any?(services, fn service ->
          Map.get(service, "node") == node_name and
            Map.get(service, "status") == "passing" and
            ServiceSpec.match_requirement?(service, requirement)
        end)

      _ ->
        false
    end
  end

  defp filter_services(services, opts) do
    name = option_string(opts, :name)
    node = option_string(opts, :node)
    job_id = option_string(opts, :job_id)
    agent_id = option_string(opts, :agent_id)
    status = option_string(opts, :status)
    tags = opts |> Keyword.get(:tags, []) |> List.wrap() |> Enum.map(&to_string/1)
    passing_only = Keyword.get(opts, :passing_only, false)

    Enum.filter(services, fn service ->
      (is_nil(name) or Map.get(service, "name") == name) and
        (is_nil(node) or Map.get(service, "node") == node) and
        (is_nil(job_id) or Map.get(service, "job_id") == job_id) and
        (is_nil(agent_id) or Map.get(service, "agent_id") == agent_id) and
        (is_nil(status) or Map.get(service, "status") == status) and
        (not passing_only or Map.get(service, "status") == "passing") and
        tags_subset?(tags, Map.get(service, "tags", []))
    end)
  end

  defp option_string(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      "" -> nil
      value -> to_string(value)
    end
  end

  defp tags_subset?([], _service_tags), do: true

  defp tags_subset?(tags, service_tags) do
    service_tags = service_tags |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()
    Enum.all?(tags, &MapSet.member?(service_tags, &1))
  end

  defp stringify_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
