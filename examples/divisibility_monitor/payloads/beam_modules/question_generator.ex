defmodule MirrorNeuron.Examples.DivisibilityMonitor.QuestionGenerator do
  use MirrorNeuron.AgentTemplate

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config || %{},
       asked: 0
     }}
  end

  @impl true
  def handle_message(message, state, _context) do
    case type(message) do
      "division_answer" ->
        Process.sleep(interval_ms(state.config))
        emit_next_question(state)

      _ ->
        emit_next_question(state)
    end
  end

  def inspect_state(state) do
    %{asked: state.asked}
  end

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
