defmodule MirrorNeuron.Persistence.RedisStore.JobDefinitions do
  @moduledoc "Stable job definitions and conditional revision updates."

  alias MirrorNeuron.Persistence.RedisStore.Connection
  alias MirrorNeuron.Persistence.RedisStore.Keys
  alias MirrorNeuron.Persistence.RedisStore.Results
  alias MirrorNeuron.Persistence.RedisStore.Values

  @job_definitions_set "job-definitions"

  @doc """
  Persists a stable job definition independently from execution records.

  Execution records use `job:<run_id>`. Stable definitions use
  `job-definition:<job_id>` so the two identities cannot overwrite one another.
  """
  def persist_job_definition(job_id, definition) when is_map(definition) do
    with :ok <- Values.validate_identifier("job_id", job_id) do
      definition =
        definition
        |> Values.stringify_map()
        |> Map.put("job_id", job_id)
        |> Map.put_new("created_at", Values.timestamp())
        |> Map.put("updated_at", Values.timestamp())

      with {:ok, results} <-
             Connection.transaction([
               ["SET", Keys.key("job-definition", job_id), Jason.encode!(definition)],
               ["SADD", Keys.key(@job_definitions_set), job_id]
             ]),
           :ok <- Results.expect_no_redis_errors(results),
           :ok <- Connection.wait_for_replicas() do
        {:ok, definition}
      else
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  def persist_job_definition(_job_id, _definition),
    do: {:error, "job definition must be an object"}

  @doc false
  def create_job_definition(job_id, definition) when is_map(definition) do
    with :ok <- Values.validate_identifier("job_id", job_id),
         {:ok, result} <-
           Connection.command([
             "EVAL",
             """
             if redis.call('EXISTS', KEYS[1]) == 1 then return 0 end
             redis.call('SET', KEYS[1], ARGV[1])
             redis.call('SADD', KEYS[2], ARGV[2])
             return 1
             """,
             "2",
             Keys.key("job-definition", job_id),
             Keys.key(@job_definitions_set),
             Jason.encode!(definition),
             job_id
           ]) do
      case result do
        1 -> with :ok <- Connection.wait_for_replicas(), do: {:ok, definition}
        0 -> {:error, :job_already_exists}
        _ -> {:error, :invalid_definition_store_result}
      end
    end
  end

  @doc false
  def compare_job_definition(job_id, revision, definition) when is_map(definition) do
    with :ok <- Values.validate_identifier("job_id", job_id),
         {:ok, result} <-
           Connection.command([
             "EVAL",
             """
             local prior = redis.call('GET', KEYS[1])
             if not prior or tonumber(cjson.decode(prior).revision) ~= tonumber(ARGV[1]) then return 0 end
             redis.call('SET', KEYS[1], ARGV[2])
             return 1
             """,
             "1",
             Keys.key("job-definition", job_id),
             to_string(revision),
             Jason.encode!(definition)
           ]) do
      case result do
        1 -> with :ok <- Connection.wait_for_replicas(), do: {:ok, definition}
        0 -> {:error, :revision_mismatch}
        _ -> {:error, :invalid_definition_store_result}
      end
    end
  end

  def fetch_job_definition(job_id) do
    with :ok <- Values.validate_identifier("job_id", job_id) do
      case Connection.command(["GET", Keys.key("job-definition", job_id)]) do
        {:ok, nil} -> {:error, "job #{job_id} was not found"}
        {:ok, contents} -> Jason.decode(contents)
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  def job_definition_exists?(job_id) do
    with :ok <- Values.validate_identifier("job_id", job_id) do
      case Connection.command(["EXISTS", Keys.key("job-definition", job_id)]) do
        {:ok, 0} -> {:ok, false}
        {:ok, "0"} -> {:ok, false}
        {:ok, _count} -> {:ok, true}
        {:error, reason} -> {:error, Values.format_reason(reason)}
      end
    end
  end

  def list_job_definitions do
    with {:ok, job_ids} <- Connection.command(["SMEMBERS", Keys.key(@job_definitions_set)]) do
      job_ids
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn job_id, {:ok, definitions} ->
        case fetch_job_definition(job_id) do
          {:ok, definition} -> {:cont, {:ok, [definition | definitions]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, definitions} -> {:ok, Enum.reverse(definitions)}
        error -> error
      end
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end

  def delete_job_definition(job_id) do
    with :ok <- Values.validate_identifier("job_id", job_id),
         {:ok, results} <-
           Connection.transaction([
             ["DEL", Keys.key("job-definition", job_id)],
             ["SREM", Keys.key(@job_definitions_set), job_id]
           ]),
         :ok <- Results.expect_no_redis_errors(results),
         :ok <- Connection.wait_for_replicas() do
      :ok
    else
      {:error, reason} -> {:error, Values.format_reason(reason)}
    end
  end
end
