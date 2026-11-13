defmodule MirrorNeuron.Builtins.Executor.Decoding do
  @moduledoc "Recognizes structured worker output and rejects retired completion contracts."

  def decode_structured_result(result) do
    with {:ok, decoded} <- decoded_result_payload(result) do
      cond do
        retired_completion_payload?(decoded) ->
          {:error,
           %{
             "error" => "unsupported structured output key",
             "unsupported_keys" => retired_completion_keys(decoded),
             "message" => "Use complete_step or complete_run instead of complete_job"
           }}

        structured_payload?(decoded) ->
          validate_actions(decoded)

        true ->
          :ignore
      end
    else
      _ -> :ignore
    end
  end

  defp validate_actions(payload) do
    with :ok <- validate_action_list(payload, "events"),
         :ok <- validate_action_list(payload, "emit_messages"),
         :ok <- validate_message_encodings(Map.get(payload, "emit_messages", [])) do
      {:ok, payload}
    end
  end

  defp validate_action_list(payload, key) do
    if is_list(Map.get(payload, key, [])) do
      :ok
    else
      invalid_result("#{key} must be a list")
    end
  end

  defp validate_message_encodings(messages) do
    Enum.reduce_while(messages, :ok, fn
      %{"body_base64" => body}, :ok ->
        if is_binary(body) and match?({:ok, _}, Base.decode64(body)) do
          {:cont, :ok}
        else
          {:halt, invalid_result("emit_messages body_base64 must be valid base64")}
        end

      _message, :ok ->
        {:cont, :ok}
    end)
  end

  defp invalid_result(reason),
    do:
      {:error,
       %{"error" => "invalid structured output", "reason" => reason, "retryable" => false}}

  def decoded_result_payload(%{"structured_result" => decoded}) when is_map(decoded),
    do: {:ok, decoded}

  def decoded_result_payload(result) do
    with stdout when is_binary(stdout) and stdout != "" <- Map.get(result, "stdout"),
         {:ok, decoded} <- Jason.decode(stdout) do
      {:ok, decoded}
    else
      _ -> :ignore
    end
  end

  defp structured_payload?(decoded) when is_map(decoded) do
    Enum.any?(
      ["event_result", "emit_messages", "events", "next_state", "complete_step", "complete_run"],
      &Map.has_key?(decoded, &1)
    )
  end

  defp structured_payload?(_decoded), do: false

  defp retired_completion_payload?(decoded) when is_map(decoded) do
    Enum.any?(["complete_job", "complete_job?"], &Map.has_key?(decoded, &1))
  end

  defp retired_completion_payload?(_decoded), do: false

  defp retired_completion_keys(decoded) when is_map(decoded) do
    Enum.filter(["complete_job", "complete_job?"], &Map.has_key?(decoded, &1))
  end

  def sdk_step_result?(decoded) do
    is_map(Map.get(decoded, "outputs")) and
      is_list(Map.get(decoded, "artifacts")) and
      is_map(Map.get(decoded, "metrics")) and
      is_binary(Map.get(decoded, "status"))
  end
end
