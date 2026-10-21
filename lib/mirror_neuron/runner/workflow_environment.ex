defmodule MirrorNeuron.Runner.WorkflowEnvironment do
  @moduledoc false
  alias MirrorNeuron.Message

  # Runtime headers outrank definition-time environment values. In particular,
  # a CLI blueprint run label is not the physical workflow run identity.
  def from_options(opts) do
    headers =
      case Keyword.get(opts, :message) do
        message when is_map(message) -> Message.headers(message)
        _ -> %{}
      end

    fields = %{
      "MN_BLOCK_EVENT_PROTOCOL" => "mn.block_events/v1",
      "MN_BLOCK_EVENT_PUBLICATION_PROTOCOL" => "mn.published_files/v1",
      "MN_WORKFLOW_RUN_ID" => headers["mn.workflow.run_id"] || Keyword.get(opts, :run_id),
      "MN_WORKFLOW_STEP_ID" => headers["mn.workflow.step_id"],
      "MN_WORKFLOW_GRAPH_REVISION" => headers["mn.workflow.graph_revision"],
      "MN_WORKFLOW_TEMPLATE_ID" => headers["mn.workflow.template_id"],
      "MN_WORKFLOW_REGION_ID" => headers["mn.workflow.region_id"],
      "MN_WORKFLOW_ATTEMPT_ID" => headers["mn.workflow.attempt_id"],
      "MN_WORKFLOW_ATTEMPT" => headers["mn.workflow.attempt"],
      "MN_WORKFLOW_DEADLINE_AT" => headers["mn.workflow.deadline_at"],
      "MN_WORKFLOW_HEARTBEAT_DEADLINE_AT" => headers["mn.workflow.heartbeat_deadline_at"],
      "MN_WORKFLOW_STEP_IDEMPOTENCY_KEY" => headers["mn.workflow.idempotency_key"],
      "MN_WORKFLOW_IDEMPOTENCY_KEY" => invocation_key(Keyword.get(opts, :message))
    }

    fields
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
  end

  def invocation_key(message) when is_map(message) do
    case Message.headers(message)["mn.workflow.idempotency_key"] do
      key when is_binary(key) and key != "" ->
        [key, Message.to(message), Message.id(message)]
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      _ ->
        nil
    end
  end

  def invocation_key(_message), do: nil
end
