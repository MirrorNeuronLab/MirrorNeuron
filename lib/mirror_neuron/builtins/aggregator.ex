defmodule MirrorNeuron.Builtins.Aggregator do
  use MirrorNeuron.AgentTemplate

  alias MirrorNeuron.AgentTemplates.Accumulator

  @impl true
  def init(node) do
    Accumulator.init(node,
      complete_on_message: Map.get(node.config, "complete_on_message", false)
    )
  end

  @impl true
  def handle_message(message, state, _context) do
    Accumulator.collect(message, state,
      event_type: :aggregator_received,
      build_result: &aggregate/3
    )
  end

  defp aggregate(messages, config, last_message) do
    case Map.get(config, "mode") do
      "prime_sweep" -> aggregate_prime_sweep(messages)
      _ -> %{"messages" => messages, "count" => length(messages), "last_message" => last_message}
    end
  end

  defp aggregate_prime_sweep(messages) do
    chunk_results =
      Enum.map(messages, fn payload ->
        chunk =
          payload
          |> get_in(["sandbox", "stdout"])
          |> Jason.decode!()

        %{
          "agent_id" => payload["agent_id"],
          "worker_id" => chunk["worker_id"],
          "range_start" => chunk["range_start"],
          "range_end" => chunk["range_end"],
          "checked_numbers" => chunk["checked_numbers"],
          "prime_count" => chunk["prime_count"],
          "primes" => chunk["primes"]
        }
      end)

    primes =
      chunk_results
      |> Enum.flat_map(& &1["primes"])
      |> Enum.sort()

    checked_numbers =
      chunk_results
      |> Enum.map(& &1["checked_numbers"])
      |> Enum.sum()

    sorted_chunks = Enum.sort_by(chunk_results, & &1["range_start"])

    %{
      "mode" => "prime_sweep",
      "worker_count" => length(chunk_results),
      "checked_numbers" => checked_numbers,
      "prime_count" => length(primes),
      "range_start" => sorted_chunks |> List.first() |> Map.get("range_start"),
      "range_end" => sorted_chunks |> List.last() |> Map.get("range_end"),
      "first_25_primes" => Enum.take(primes, 25),
      "last_25_primes" => Enum.take(Enum.reverse(primes), 25) |> Enum.reverse(),
      "chunks" => Enum.map(sorted_chunks, &Map.drop(&1, ["primes"]))
    }
  end
end
