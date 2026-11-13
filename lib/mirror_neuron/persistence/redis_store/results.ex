defmodule MirrorNeuron.Persistence.RedisStore.Results do
  @moduledoc "Validates Redis transaction and pipeline receipts before acknowledging writes."

  alias MirrorNeuron.Persistence.RedisStore.Values

  def parse_transaction_results(["OK" | queued_and_exec]) do
    case List.last(queued_and_exec) do
      exec_results when is_list(exec_results) ->
        case Enum.find(Enum.drop(queued_and_exec, -1), &match?(%Redix.Error{}, &1)) do
          nil ->
            with :ok <- expect_no_redis_errors(exec_results), do: {:ok, exec_results}

          error ->
            {:error, Values.format_reason(error)}
        end

      nil ->
        {:error, "missing Redis transaction EXEC result"}

      %Redix.Error{} = error ->
        {:error, Values.format_reason(error)}

      other ->
        {:error, Values.format_reason(other)}
    end
  end

  def parse_transaction_results([%Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def parse_transaction_results(other), do: {:error, Values.format_reason(other)}

  def expect_persist_job_results(["OK", "OK", "OK", count]) when is_integer(count), do: :ok

  def expect_persist_job_results([%Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_job_results([_set, %Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_job_results([_set, _summary, %Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_job_results([_set, _summary, _guard, %Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_job_results(other), do: {:error, Values.format_reason(other)}

  def expect_persist_job_projection_results(["OK", "OK", count]) when is_integer(count),
    do: :ok

  def expect_persist_job_projection_results([%Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_job_projection_results([_summary, %Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_job_projection_results([_summary, _guard, %Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_job_projection_results(other), do: {:error, Values.format_reason(other)}

  def expect_persist_agent_results(["OK", "OK", count | retention_results])
      when is_integer(count),
      do: expect_no_redis_errors(retention_results)

  def expect_persist_agent_results([%Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_agent_results([_set, %Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_agent_results([_set, _summary, %Redix.Error{} = error | _]),
    do: {:error, Values.format_reason(error)}

  def expect_persist_agent_results(other), do: {:error, Values.format_reason(other)}

  def expect_first_result([%Redix.Error{} = error | _], _predicate),
    do: {:error, Values.format_reason(error)}

  def expect_first_result([value | _], predicate) do
    if predicate.(value), do: :ok, else: {:error, Values.format_reason(value)}
  end

  def expect_first_result([], _predicate), do: {:error, "missing Redis pipeline result"}

  def expect_no_redis_errors(results) when is_list(results) do
    case Enum.find(results, &match?(%Redix.Error{}, &1)) do
      nil -> :ok
      %Redix.Error{} = error -> {:error, Values.format_reason(error)}
    end
  end

  def expect_no_redis_errors(other), do: {:error, Values.format_reason(other)}
end
