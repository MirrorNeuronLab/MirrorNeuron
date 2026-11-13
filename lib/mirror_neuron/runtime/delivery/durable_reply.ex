defmodule MirrorNeuron.Runtime.DurableReply do
  @moduledoc "Short native submission/status RPCs backed by durable reply operations."
  alias MirrorNeuron.ModelServices
  @schema "mn.mcp.job_reply_operation.v1"

  def query(payload, timeout) do
    context = payload["context"] || %{}

    if Enum.any?(Map.keys(context), &String.starts_with?(&1, "_mn_")) do
      ModelServices.job_response_command(payload, 5_000)
    else
      request_id =
        if payload["request_id"] in [nil, ""],
          do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
          else: payload["request_id"]

      payload = Map.merge(payload, %{"request_id" => request_id, "durable" => true})
      deadline = System.monotonic_time(:millisecond) + timeout

      with {:ok, operation} <- ModelServices.job_response_command(payload, 5_000) do
        await(payload, operation, deadline)
      end
    end
  end

  defp await(
         payload,
         %{"schema_version" => @schema, "status" => "completed", "response" => result},
         _deadline
       ),
       do: {:ok, Map.put(result, "request_id", payload["request_id"])}

  defp await(payload, %{"schema_version" => @schema} = operation, deadline) do
    cond do
      operation["status"] in ["failed", "cancelled", "interrupted"] ->
        {:ok, Map.merge(operation, %{"accepted" => true, "request_id" => payload["request_id"]})}

      System.monotonic_time(:millisecond) >= deadline ->
        {:ok, Map.merge(operation, %{"accepted" => true, "request_id" => payload["request_id"]})}

      true ->
        Process.sleep(100)
        read = put_in(payload, ["context", "_mn_response_work"], %{"action" => "read"})

        case ModelServices.job_response_command(read, 5_000) do
          {:ok, next} ->
            await(payload, next, deadline)

          {:error, _} ->
            {:ok, Map.merge(operation, %{"accepted" => true, "observation" => "unavailable"})}
        end
    end
  end

  defp await(_payload, answer, _deadline), do: {:ok, answer}
end
