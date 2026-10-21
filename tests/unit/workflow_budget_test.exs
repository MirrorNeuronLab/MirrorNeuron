defmodule MirrorNeuron.Runtime.WorkflowBudgetTest do
  use ExUnit.Case, async: true
  alias MirrorNeuron.Runtime.WorkflowBudget

  defmodule Owner do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init({policies, persist}), do: {:ok, {%{}, policies, persist}}

    def handle_call({:workflow_budget, attrs}, _, {ledger, policies, persist} = state) do
      case WorkflowBudget.apply_command(ledger, policies, "run", attrs, persist) do
        {:ok, result, next} -> {:reply, {:ok, result}, {next, policies, persist}}
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  defp policies(limit \\ 3), do: %{"workflow_budgets" => %{"research" => %{"limit" => limit}}}

  defp request(id \\ 1, limit \\ 3) do
    %{
      "operation" => "workflow_budget",
      "schema" => "mn.workflow_budget/v1",
      "action" => "start",
      "job_id" => "job",
      "run_id" => "run",
      "name" => "research",
      "limit" => limit,
      "request_id" => :crypto.hash(:sha256, to_string(id)) |> Base.encode16(case: :lower),
      "action_type" => "llm_call",
      "stage" => "research",
      "entity_id" => "acme",
      "tool" => "model",
      "scope" => "worker-#{id}",
      "revision" => "test-v1",
      "metadata" => %{}
    }
  end

  defp summary_request(limit \\ 3),
    do:
      request(1, limit)
      |> Map.take(~w(operation schema job_id run_id name limit))
      |> Map.put("action", "summary")

  defp complete_request(request, status \\ "completed") do
    request
    |> Map.take(~w(operation schema job_id run_id name limit request_id scope revision))
    |> Map.merge(%{"action" => "complete", "status" => status, "metadata" => %{"tokens" => 42}})
  end

  test "concurrent workers share one durable allowance" do
    parent = self()

    owner =
      start_supervised!(
        {Owner,
         {policies(),
          fn state ->
            send(parent, {:persisted, state})
            :ok
          end}}
      )

    results =
      1..12
      |> Task.async_stream(
        fn id ->
          WorkflowBudget.command(request(id), owner: fn "job" -> owner end)
        end,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert Enum.count(results, &(&1["status"] == "admitted")) == 3
    assert Enum.count(results, &(&1["status"] == "budget_exhausted")) == 9
    assert {:ok, ledger} = WorkflowBudget.command(summary_request(), owner: fn _ -> owner end)
    assert ledger["used"] == 3 and ledger["remaining"] == 0
    assert length(ledger["actions"]) == 12
    assert Enum.sum(Enum.map(ledger["actions"], & &1["cost"])) == 3
    assert_receive {:persisted, _}

    for id <- 1..12 do
      assert {:ok, _} = WorkflowBudget.command(request(id), owner: fn _ -> owner end)
    end

    assert {:ok, replay} = WorkflowBudget.command(summary_request(), owner: fn _ -> owner end)
    assert replay == ledger
  end

  test "a reservation is never acknowledged before durable persistence" do
    assert {:error, _} =
             WorkflowBudget.apply_command(%{}, policies(), "run", request(), fn _ ->
               {:error, :offline}
             end)

    parent = self()

    assert {:ok, admitted, state} =
             WorkflowBudget.apply_command(%{}, policies(), "run", request(), fn value ->
               send(parent, {:saved, value})
               {:ok, value}
             end)

    assert_receive {:saved, ^state}
    assert admitted["status"] == "admitted"

    assert {:ok, ^admitted, ^state} =
             WorkflowBudget.apply_command(state, policies(), "run", request(), fn _ ->
               flunk("An observed durable reservation was written twice")
             end)
  end

  test "lost replies and JSON restoration cannot refund or double-charge work" do
    assert {:ok, admitted, state} = WorkflowBudget.transition(%{}, policies(), "run", request())
    restored = state |> Jason.encode!() |> Jason.decode!()

    assert {:ok, ^admitted, ^restored} =
             WorkflowBudget.transition(restored, policies(), "run", request())

    assert {:ok, summary, _} =
             WorkflowBudget.transition(restored, policies(), "run", summary_request())

    assert summary["used"] == 1
    assert hd(summary["actions"])["status"] == "started"
  end

  test "completion is scoped, durable and idempotent" do
    assert {:ok, _, state} = WorkflowBudget.transition(%{}, policies(), "run", request())

    assert {:error, _} =
             WorkflowBudget.transition(
               state,
               policies(),
               "run",
               Map.put(complete_request(request()), "scope", "another-worker")
             )

    assert {:ok, response, done} =
             WorkflowBudget.transition(state, policies(), "run", complete_request(request()))

    assert {:ok, ^response, ^done} =
             WorkflowBudget.transition(done, policies(), "run", complete_request(request()))

    assert {:error, _} =
             WorkflowBudget.transition(
               done,
               policies(),
               "run",
               complete_request(request(), "failed")
             )

    assert {:ok, summary, _} =
             WorkflowBudget.transition(done, policies(), "run", summary_request())

    assert summary["used"] == 1
    assert hd(summary["actions"])["metadata"] == %{"tokens" => 42}
  end

  test "changed requests, declarations and runs reject before persistence" do
    assert {:ok, _, state} = WorkflowBudget.transition(%{}, policies(), "run", request())

    assert {:error, _} =
             WorkflowBudget.transition(
               state,
               policies(),
               "run",
               Map.put(request(), "metadata", %{"query" => "changed"})
             )

    assert {:error, _} =
             WorkflowBudget.transition(state, policies(4), "run", Map.put(request(), "limit", 4))

    assert {:error, _} = WorkflowBudget.transition(state, policies(), "another-run", request())

    assert {:error, _} =
             WorkflowBudget.transition(
               state,
               policies(),
               "run",
               Map.put(request(), "name", "undeclared")
             )

    assert {:error, _} =
             WorkflowBudget.transition(state, policies(), "run", Map.put(request(), "limit", 999))
  end

  test "invalid accounting cannot admit another action" do
    assert {:ok, _, state} = WorkflowBudget.transition(%{}, policies(), "run", request())

    for malformed <- [
          put_in(state, ["pools", "research", "used"], 0),
          put_in(state, ["pools", "research"], "bad"),
          put_in(
            state,
            ["pools", "research", "actions", request()["request_id"], "action", "action_index"],
            2
          )
        ] do
      assert {:error, _} = WorkflowBudget.transition(malformed, policies(), "run", request(2))
    end
  end

  test "invalid wire data and missing owners fail closed" do
    for malformed <- [
          nil,
          Map.put(request(), "extra", true),
          Map.put(request(), "metadata", []),
          Map.put(request(), "metadata", %{"body" => String.duplicate("x", 16385)}),
          Map.put(request(), "request_id", "../bad"),
          Map.put(request(), "schema", "future")
        ] do
      assert {:error, _} =
               WorkflowBudget.command(malformed,
                 owner: fn _ -> flunk("Invalid request reached owner") end
               )
    end

    assert {:error, _} =
             WorkflowBudget.command(request(), owner: fn _ -> :nonexistent_budget_owner end)
  end

  test "zero allowance denies work and completion cannot invent a reservation" do
    assert {:ok, result, state} =
             WorkflowBudget.transition(%{}, policies(0), "run", request(1, 0))

    assert result["status"] == "budget_exhausted"

    assert {:error, _} =
             WorkflowBudget.transition(state, policies(0), "run", complete_request(request(1, 0)))

    assert {:ok, result, _} =
             WorkflowBudget.transition(state, policies(0), "run", summary_request(0))

    assert result["used"] == 0 and result["exhausted"]
  end

  test "declarations are finite and Core does not resolve worker-supplied limits" do
    for invalid <- [
          %{"workflow_budgets" => %{}},
          %{"workflow_budgets" => %{"a" => %{"limit" => -1}}},
          %{"workflow_budgets" => %{"a" => %{"config_path" => ["budget"]}}},
          %{"workflow_budgets" => %{"../bad" => %{"limit" => 1}}}
        ] do
      assert {:error, _} = WorkflowBudget.validate_declarations(invalid)
    end

    assert :ok = WorkflowBudget.validate_declarations(%{})
  end

  test "journal byte capacity rejects work before granting it" do
    {state, rejected} =
      Enum.reduce_while(1..200, {%{}, nil}, fn id, {state, _} ->
        attrs = Map.put(request(id, 500), "metadata", %{"body" => String.duplicate("x", 15000)})

        case WorkflowBudget.transition(state, policies(500), "run", attrs) do
          {:ok, _, next} -> {:cont, {next, nil}}
          {:error, reason} -> {:halt, {state, {id, reason}}}
        end
      end)

    assert {id, reason} = rejected
    assert reason =~ "byte capacity"
    assert id > 1 and id < 200
    assert state["pools"]["research"]["used"] == id - 1
    assert byte_size(Jason.encode!(state["pools"]["research"])) <= 4_000_000
  end

  test "paused coordinators cannot admit work" do
    state = %{status: "paused"}

    assert {:reply, {:error, _}, ^state} =
             MirrorNeuron.Runtime.JobCoordinator.handle_call(
               {:workflow_budget, request()},
               nil,
               state
             )
  end
end
