defmodule MirrorNeuron.RuntimeTest.WorkflowFirstRunner do
  def run(_payload, _config, _opts) do
    {:ok,
     %{
       "sandbox_name" => "workflow-first",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "emit_messages" => [
             %{
               "type" => "step_a_done",
               "body" => %{"from" => "step_a"}
             }
           ],
           "complete_step" => %{"from" => "step_a"}
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.WorkflowSecondRunner do
  def run(payload, _config, _opts) do
    {:ok,
     %{
       "sandbox_name" => "workflow-second",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "emit_messages" => [
             %{
               "type" => "workflow_done",
               "body" => %{"done" => true, "payload" => payload}
             }
           ],
           "complete_step" => %{"done" => true, "payload" => payload}
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.ExplicitCheckpointAgent do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(_node), do: {:ok, %{messages: 0}}

  @impl true
  def handle_message(_message, state, _context) do
    next_state = %{state | messages: state.messages + 1}

    {:ok, next_state,
     [
       {:checkpoint,
        %{
          "agent_id" => "checkpoint_agent",
          "processed_messages" => next_state.messages,
          "metadata" => %{"explicit_checkpoint" => true}
        }}
     ]}
  end
end

defmodule MirrorNeuron.RuntimeTest.DurableCounterAgent do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    {:ok, %{count: 0, target: Map.get(node.config, "target", 12), seen_ids: []}}
  end

  @impl true
  def handle_message(message, state, _context) do
    payload = payload(message) || %{}
    message_id = Map.get(payload, "id")

    cond do
      is_nil(message_id) ->
        {:ok, state, [{:event, :counter_control_ignored, %{"count" => state.count}}]}

      message_id in state.seen_ids ->
        {:ok, state,
         [{:event, :counter_duplicate_ignored, %{"id" => message_id, "count" => state.count}}]}

      true ->
        seen_ids = state.seen_ids ++ [message_id]

        next_state = %{state | count: state.count + 1, seen_ids: seen_ids}

        actions = [{:event, :counter_step_completed, %{"count" => next_state.count}}]

        actions =
          if next_state.count >= next_state.target do
            actions ++
              [
                {:complete_run,
                 %{
                   "count" => next_state.count,
                   "seen_ids" => next_state.seen_ids
                 }}
              ]
          else
            actions
          end

        {:ok, next_state, actions}
    end
  end
end

defmodule MirrorNeuron.RuntimeTest.ContextRouterAgent do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(_node), do: {:ok, %{domain: nil, confidence: 0.0}}

  @impl true
  def handle_message(message, _state, _context) do
    payload = payload(message) || %{}
    domain = Map.get(payload, "domain", "general")
    confidence = Map.get(payload, "confidence", 0.0)
    next_state = %{domain: domain, confidence: confidence}

    {:ok, next_state,
     [
       {:emit, "classified_request", %{"domain" => domain, "confidence" => confidence}},
       {:event, :classification_state_updated, %{"domain" => domain, "confidence" => confidence}}
     ]}
  end
end
