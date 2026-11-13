defmodule MirrorNeuron.Persistence.RedisStore.FederationProjections do
  @moduledoc "Remote owner projections and their per-owner discovery indexes."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Values

  @doc false
  def put_federation_projections(owner_node, kind, summaries)
      when is_binary(owner_node) and kind in ["job", "run"] and is_list(summaries) do
    persist_federation_projections(owner_node, kind, summaries, false)
  end

  @doc false
  def replace_federation_projections(owner_node, kind, summaries)
      when is_binary(owner_node) and kind in ["job", "run"] and is_list(summaries) do
    persist_federation_projections(owner_node, kind, summaries, true)
  end

  @doc false
  def list_federation_projections(owner_node, kind)
      when is_binary(owner_node) and kind in ["job", "run"] do
    with :ok <- Values.validate_identifier("owner_node", owner_node),
         {:ok, resource_ids} <-
           Connection.command(["SMEMBERS", federation_projection_index(kind, owner_node)]) do
      resource_ids = Enum.sort(resource_ids)

      case resource_ids do
        [] ->
          {:ok, []}

        _ ->
          keys = Enum.map(resource_ids, &federation_projection_key(kind, owner_node, &1))

          case Connection.command(["MGET" | keys]) do
            {:ok, values} ->
              projections =
                values
                |> Enum.reject(&is_nil/1)
                |> Enum.flat_map(fn encoded ->
                  case Jason.decode(encoded) do
                    {:ok, projection} when is_map(projection) -> [projection]
                    _ -> []
                  end
                end)

              {:ok, projections}

            {:error, reason} ->
              {:error, Values.format_reason(reason)}
          end
      end
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  @doc false
  def fetch_federation_projection(owner_node, kind, resource_id)
      when is_binary(owner_node) and kind in ["job", "run"] and is_binary(resource_id) do
    with :ok <- Values.validate_identifier("owner_node", owner_node),
         :ok <- Values.validate_identifier("resource_id", resource_id) do
      case Connection.command(["GET", federation_projection_key(kind, owner_node, resource_id)]) do
        {:ok, nil} -> {:error, :not_found}
        {:ok, encoded} -> Jason.decode(encoded)
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  @doc false
  def delete_federation_projection(owner_node, kind, resource_id)
      when is_binary(owner_node) and kind in ["job", "run"] and is_binary(resource_id) do
    with :ok <- Values.validate_identifier("owner_node", owner_node),
         :ok <- Values.validate_identifier("resource_id", resource_id),
         {:ok, results} <-
           Connection.transaction([
             ["DEL", federation_projection_key(kind, owner_node, resource_id)],
             ["SREM", federation_projection_index(kind, owner_node), resource_id]
           ]),
         :ok <- Results.expect_no_redis_errors(results) do
      :ok
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  @doc false
  def delete_federation_projections(owner_node) when is_binary(owner_node) do
    Enum.reduce_while(["job", "run"], :ok, fn kind, :ok ->
      case list_federation_projection_ids(owner_node, kind) do
        {:ok, resource_ids} ->
          commands =
            Enum.map(resource_ids, fn resource_id ->
              ["DEL", federation_projection_key(kind, owner_node, resource_id)]
            end) ++ [["DEL", federation_projection_index(kind, owner_node)]]

          case Connection.transaction(commands) do
            {:ok, results} ->
              case Results.expect_no_redis_errors(results) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end

            {:error, reason} ->
              {:halt, {:error, Values.format_reason(reason)}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp persist_federation_projections(owner_node, kind, summaries, replace?) do
    with :ok <- Values.validate_identifier("owner_node", owner_node),
         {:ok, projections} <- normalize_federation_projections(kind, summaries),
         {:ok, previous_ids} <-
           if(replace?, do: list_federation_projection_ids(owner_node, kind), else: {:ok, []}) do
      projection_ids = Map.keys(projections)
      removed_ids = if replace?, do: previous_ids -- projection_ids, else: []

      delete_commands =
        Enum.flat_map(removed_ids, fn resource_id ->
          [
            ["DEL", federation_projection_key(kind, owner_node, resource_id)],
            ["SREM", federation_projection_index(kind, owner_node), resource_id]
          ]
        end)

      replace_index_commands =
        if replace?, do: [["DEL", federation_projection_index(kind, owner_node)]], else: []

      write_commands =
        projections
        |> Enum.flat_map(fn {resource_id, projection} ->
          [
            [
              "SET",
              federation_projection_key(kind, owner_node, resource_id),
              Jason.encode!(projection)
            ],
            ["SADD", federation_projection_index(kind, owner_node), resource_id]
          ]
        end)

      with {:ok, results} <-
             Connection.transaction(delete_commands ++ replace_index_commands ++ write_commands),
           :ok <- Results.expect_no_redis_errors(results),
           :ok <- Connection.wait_for_replicas() do
        {:ok, Map.values(projections)}
      else
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  defp normalize_federation_projections(kind, summaries) do
    id_field = if kind == "job", do: "job_id", else: "run_id"

    summaries
    |> Enum.reduce_while({:ok, %{}}, fn summary, {:ok, acc} ->
      normalized = Values.stringify_map(summary)
      resource_id = to_string(Map.get(normalized, id_field) || "") |> String.trim()

      if resource_id == "" do
        {:halt, {:error, "#{id_field} must be a non-empty string"}}
      else
        {:cont, {:ok, Map.put(acc, resource_id, normalized)}}
      end
    end)
  end

  defp list_federation_projection_ids(owner_node, kind) do
    with :ok <- Values.validate_identifier("owner_node", owner_node) do
      case Connection.command(["SMEMBERS", federation_projection_index(kind, owner_node)]) do
        {:ok, resource_ids} -> {:ok, resource_ids}
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  defp federation_projection_index(kind, owner_node),
    do: Keys.key("federation-projections", kind, owner_node)

  defp federation_projection_key(kind, owner_node, resource_id),
    do: Keys.key("federation-projection", kind, owner_node, resource_id)
end
