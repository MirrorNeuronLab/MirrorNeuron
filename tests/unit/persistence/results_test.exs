defmodule MirrorNeuron.Persistence.RedisStore.ResultsTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Persistence.RedisStore.Results

  test "a successful transaction preserves command results and order" do
    assert {:ok, ["OK", 3, nil]} =
             Results.parse_transaction_results([
               "OK",
               "QUEUED",
               "QUEUED",
               "QUEUED",
               ["OK", 3, nil]
             ])
  end

  test "an error while queueing cannot be mistaken for a committed transaction" do
    error = %Redix.Error{message: "ERR invalid command"}
    assert {:error, reason} = Results.parse_transaction_results(["OK", error, ["OK"]])
    assert reason =~ "ERR invalid command"
  end

  test "a command failure inside EXEC is not acknowledged as a successful write" do
    error = %Redix.Error{message: "WRONGTYPE cannot update index"}

    assert {:error, reason} =
             Results.parse_transaction_results(["OK", "QUEUED", "QUEUED", ["OK", error]])

    assert reason =~ "WRONGTYPE"
  end

  test "a missing or aborted EXEC result is an error" do
    for result <- [
          ["OK"],
          ["OK", "QUEUED", nil],
          ["OK", "QUEUED", %Redix.Error{message: "EXECABORT"}]
        ] do
      assert {:error, _} = Results.parse_transaction_results(result)
    end
  end

  test "job receipts reject errors in every write position" do
    for index <- 0..3 do
      results =
        List.replace_at(["OK", "OK", "OK", 1], index, %Redix.Error{message: "failed #{index}"})

      assert {:error, reason} = Results.expect_persist_job_results(results)
      assert reason =~ "failed #{index}"
    end
  end

  test "agent receipts include errors in trailing retention commands" do
    assert {:error, reason} =
             Results.expect_persist_agent_results([
               "OK",
               "OK",
               1,
               %Redix.Error{message: "retention failed"}
             ])

    assert reason =~ "retention failed"
  end

  test "first-result checks do not call a success predicate for a Redis error" do
    assert {:error, _} =
             Results.expect_first_result([%Redix.Error{message: "denied"}], fn _ ->
               flunk("unexpected success check")
             end)

    assert {:error, "missing Redis pipeline result"} =
             Results.expect_first_result([], fn _ -> true end)
  end
end
