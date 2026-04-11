defmodule MirrorNeuron.Examples.DivisibilityMonitor.AnswerAgent do
  use MirrorNeuron.AgentTemplate
  require Logger

  @impl true
  def init(node) do
    {:ok,
     %{
       config: node.config || %{},
       answered: 0,
       yes: 0,
       no: 0
     }}
  end

  @impl true
  def handle_message(message, state, _context) do
    case type(message) do
      "division_question" ->
        payload = payload(message) || %{}
        x = Map.get(payload, "x", 0)
        y = Map.get(payload, "y", 1)
        divisible? = y != 0 and rem(x, y) == 0
        answer = if(divisible?, do: "yes", else: "no")

        Logger.info("[DivisibilityMonitor] #{payload["question"]} #{answer}")

        next_state = %{
          state
          | answered: state.answered + 1,
            yes: state.yes + if(divisible?, do: 1, else: 0),
            no: state.no + if(divisible?, do: 0, else: 1)
        }

        response = %{
          "sequence" => Map.get(payload, "sequence"),
          "x" => x,
          "y" => y,
          "answer" => answer,
          "question" => Map.get(payload, "question")
        }

        {:ok, next_state,
         [
           {:event, :division_answered, response},
           {:emit_to, "question_generator", "division_answer", response}
         ]}

      _ ->
        {:ok, state, []}
    end
  end

  @impl true
  def inspect_state(state) do
    %{
      answered: state.answered,
      yes: state.yes,
      no: state.no
    }
  end
end
