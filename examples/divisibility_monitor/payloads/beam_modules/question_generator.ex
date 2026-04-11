defmodule MirrorNeuron.Examples.DivisibilityMonitor.QuestionGenerator do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config || %{},
       asked: 0,
       scheduled_token: nil,
       awaiting_answer: false
     }}
  end

  @impl true
  def handle_message(message, state, context) do
    case type(message) do
      "division_answer" ->
        {:ok,
         schedule_next_tick(
           %{state | awaiting_answer: false},
           context,
           interval_ms(state.config)
         ), []}

      "tick" ->
        maybe_emit_scheduled_question(message, state)

      _ ->
        {:ok, schedule_next_tick(state, context, 0), []}
    end
  end

  @impl true
  def recover(state, context) do
    if state.awaiting_answer do
      {:ok, state, []}
    else
      {:ok, schedule_next_tick(state, context, interval_ms(state.config)), []}
    end
  end

  def inspect_state(state) do
    %{asked: state.asked, awaiting_answer: state.awaiting_answer}
  end

  defp maybe_emit_scheduled_question(message, %{scheduled_token: token} = state) do
    payload = payload(message) || %{}

    if Map.get(payload, "token") == token do
      emit_next_question(%{state | scheduled_token: nil, awaiting_answer: true})
    else
      {:ok, state, []}
    end
  end

  defp maybe_emit_scheduled_question(_message, state), do: {:ok, state, []}

  defp emit_next_question(state) do
    next_asked = state.asked + 1
    x = random_between(state.config, "min_x", 10, "max_x", 500)
    y = random_between(state.config, "min_y", 2, "max_y", 25)

    payload = %{
      "sequence" => next_asked,
      "x" => x,
      "y" => y,
      "question" => "Is #{x} divisible by #{y}?"
    }

    next_state = %{state | asked: next_asked}

    {:ok, next_state,
     [
       {:event, :division_question_generated, payload},
       {:emit_to, answer_node(state.config), "division_question", payload}
     ]}
  end

  defp schedule_next_tick(state, context, delay_ms) do
    token = state.asked + 1

    spawn(fn ->
      if delay_ms > 0 do
        Process.sleep(delay_ms)
      end

      Runtime.deliver(
        context.job_id,
        context.node.node_id,
        Message.new(
          context.job_id,
          context.node.node_id,
          context.node.node_id,
          "tick",
          %{"token" => token},
          class: "control"
        )
      )
    end)

    %{state | scheduled_token: token}
  end

  defp answer_node(config) do
    Map.get(config, "answer_node", "answer_agent")
  end

  defp interval_ms(config) do
    Map.get(config, "interval_ms", 1500)
  end

  defp random_between(config, min_key, min_default, max_key, max_default) do
    min = Map.get(config, min_key, min_default)
    max = Map.get(config, max_key, max_default)
    :rand.uniform(max - min + 1) + min - 1
  end
end
