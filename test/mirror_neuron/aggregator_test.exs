defmodule MirrorNeuron.AggregatorTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.Aggregator

  test "aggregates prime chunk results and completes after the configured count" do
    node = %{
      config: %{
        "mode" => "prime_sweep",
        "complete_after" => 2
      }
    }

    {:ok, state0} = Aggregator.init(node)

    {:ok, state1, actions1} =
      Aggregator.handle_message(
        %{
          type: "prime_chunk_result",
          payload: %{
            "agent_id" => "prime_worker_0001",
            "sandbox" => %{
              "stdout" =>
                Jason.encode!(%{
                  "worker_id" => "prime_worker_0001",
                  "range_start" => 11,
                  "range_end" => 20,
                  "checked_numbers" => 10,
                  "prime_count" => 4,
                  "primes" => [11, 13, 17, 19]
                })
            }
          }
        },
        state0,
        %{}
      )

    refute Enum.any?(actions1, &match?({:complete_job, _}, &1))

    {:ok, _state2, actions2} =
      Aggregator.handle_message(
        %{
          type: "prime_chunk_result",
          payload: %{
            "agent_id" => "prime_worker_0002",
            "sandbox" => %{
              "stdout" =>
                Jason.encode!(%{
                  "worker_id" => "prime_worker_0002",
                  "range_start" => 21,
                  "range_end" => 30,
                  "checked_numbers" => 10,
                  "prime_count" => 2,
                  "primes" => [23, 29]
                })
            }
          }
        },
        state1,
        %{}
      )

    assert {:complete_job, result} = Enum.find(actions2, &match?({:complete_job, _}, &1))
    assert result["worker_count"] == 2
    assert result["checked_numbers"] == 20
    assert result["prime_count"] == 6
    assert result["first_25_primes"] == [11, 13, 17, 19, 23, 29]
    assert result["range_start"] == 11
    assert result["range_end"] == 30
  end
end
