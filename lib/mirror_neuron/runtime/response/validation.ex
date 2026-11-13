defmodule MirrorNeuron.Runtime.JobResponse.Validation do
  @moduledoc "Input limits and state guards for response questions and asynchronous turns."

  alias MirrorNeuron.Runtime.JobResponse.Lifecycle

  @max_question_chars 8_000
  @max_request_id_chars 128
  @max_context_bytes 256 * 1_024

  def validate_query(attrs) do
    question = attrs["question"]
    conversation_id = attrs["conversation_id"]
    request_id = attrs["request_id"]

    cond do
      not is_binary(question) or String.trim(question) == "" ->
        {:error, :question_required}

      String.length(question) > @max_question_chars ->
        {:error, :question_too_long}

      conversation_id not in [nil, ""] and not valid_uuid?(conversation_id) ->
        {:error, :invalid_conversation_id}

      not is_nil(request_id) and not is_binary(request_id) ->
        {:error, :invalid_request_id}

      is_binary(request_id) and String.length(request_id) > @max_request_id_chars ->
        {:error, :request_id_too_long}

      not is_map(attrs["context"] || %{}) ->
        {:error, :invalid_job_context}

      encoded_context_size(attrs["context"] || %{}) > @max_context_bytes ->
        {:error, :job_context_too_large}

      true ->
        :ok
    end
  end

  def ensure_queryable(definition) do
    cond do
      not Lifecycle.enabled?(definition) -> {:error, :response_service_disabled}
      definition["status"] != "active" -> {:error, :job_not_active}
      true -> :ok
    end
  end

  def ensure_agent_enabled(definition) do
    if bounded_agent?(definition),
      do: :ok,
      else: {:error, :response_agent_disabled}
  end

  def bounded_agent?(definition) do
    get_in(definition, ["manifest", "response_service", "agent", "kind"]) == "bounded_mcp"
  end

  def validate_turn_id(turn_id) do
    if valid_uuid?(turn_id), do: :ok, else: {:error, :invalid_turn_id}
  end

  defp valid_uuid?(value) when is_binary(value) do
    Regex.match?(
      ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\z/,
      value
    )
  end

  defp valid_uuid?(_value), do: false

  defp encoded_context_size(value) do
    value |> Jason.encode!() |> byte_size()
  rescue
    _ -> @max_context_bytes + 1
  end
end
