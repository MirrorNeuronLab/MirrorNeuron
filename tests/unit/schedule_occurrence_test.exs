defmodule MirrorNeuron.Runtime.ScheduleOccurrenceTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runtime.ScheduleOccurrence

  defmodule Store do
    def reserve_schedule_occurrence(_schedule, token, record, _lock) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.receipts[token] do
          nil -> {{:ok, :new, record}, put_in(state, [:receipts, token], record)}
          existing -> {{:ok, :existing, existing}, state}
        end
      end)
    end

    def complete_schedule_occurrence(_schedule, token, record, _lock) do
      Agent.get_and_update(__MODULE__, fn state ->
        if state.fail_commit do
          {{:error, :not_owner}, %{state | fail_commit: false}}
        else
          {:ok, put_in(state, [:receipts, token], record)}
        end
      end)
    end

    def fetch_job(id), do: Agent.get(__MODULE__, &Map.get(&1.runs, id, {:error, :not_found}))
    def put_run(id, run), do: Agent.update(__MODULE__, &put_in(&1, [:runs, id], {:ok, run}))
  end

  setup do
    start_supervised!(%{
      id: Store,
      start:
        {Agent, :start_link,
         [fn -> %{receipts: %{}, runs: %{}, fail_commit: false} end, [name: Store]]}
    })

    :ok
  end

  defp run(start, token \\ "occurrence-1") do
    ScheduleOccurrence.run(
      %{"schedule_id" => "schedule-1"},
      %{"dispatch_id" => token},
      %{},
      start,
      Store
    )
  end

  defp started(id) do
    %{
      action: "started",
      run_id: id,
      status: "pending",
      pid: nil,
      replaced_run_ids: [],
      cleanup_deferred: false,
      cleanup_pending_nodes: []
    }
  end

  test "replay returns the same execution even after its run record is removed" do
    parent = self()

    start = fn id ->
      send(parent, {:started, id})
      {:ok, started(id)}
    end

    assert {:ok, first} = run(start)
    assert {:ok, second} = run(start)
    assert first.run_id == second.run_id
    assert_receive {:started, _}
    refute_receive {:started, _}
  end

  test "reconciles a committed run after receipt persistence fails" do
    Agent.update(Store, &%{&1 | fail_commit: true})
    parent = self()

    start = fn id ->
      send(parent, {:started, id})

      Store.put_run(id, %{
        "status" => "completed",
        "manifest" => %{
          "metadata" => %{
            "schedule_dispatch" => %{
              "schedule_id" => "schedule-1",
              "dispatch_id" => "occurrence-1"
            }
          }
        }
      })

      {:ok, started(id)}
    end

    assert {:error, :not_owner} = run(start)
    assert {:ok, %{status: "completed"}} = run(start)
    assert_receive {:started, _}
    refute_receive {:started, _}
  end

  test "an interrupted reservation without a confirmed run never resubmits" do
    assert {:error, :timeout} = run(fn _ -> {:error, :timeout} end)
    assert {:error, :schedule_occurrence_unconfirmed} = run(fn _ -> flunk("duplicate start") end)
  end

  test "rejects a run belonging to a different occurrence" do
    assert {:error, :timeout} = run(fn _ -> {:error, :timeout} end)

    Store.put_run("scheduled_occurrence-1", %{
      "manifest" => %{
        "metadata" => %{
          "schedule_dispatch" => %{"schedule_id" => "different", "dispatch_id" => "occurrence-1"}
        }
      }
    })

    assert {:error, :schedule_occurrence_identity_mismatch} =
             run(fn _ -> flunk("duplicate start") end)
  end

  test "concurrent callers cannot start an occurrence twice" do
    parent = self()

    first =
      Task.async(fn ->
        run(fn id ->
          send(parent, {:reserved, self()})

          receive do
            :continue -> {:ok, started(id)}
          end
        end)
      end)

    assert_receive {:reserved, pid}
    assert {:error, :schedule_occurrence_unconfirmed} = run(fn _ -> flunk("duplicate start") end)
    send(pid, :continue)
    assert {:ok, _} = Task.await(first)
    assert {:ok, _} = run(fn _ -> flunk("duplicate start") end)
  end

  test "distinct occurrences start independent runs" do
    assert {:ok, a} = run(fn id -> {:ok, started(id)} end, "a")
    assert {:ok, b} = run(fn id -> {:ok, started(id)} end, "b")
    refute a.run_id == b.run_id
  end

  test "rejects a malformed durable reservation without launching" do
    Agent.update(
      Store,
      &put_in(&1, [:receipts, "occurrence-1"], %{"run_id" => "unrelated", "status" => "submitted"})
    )

    assert {:error, :invalid_schedule_occurrence} =
             run(fn _ -> flunk("untrusted reservation") end)
  end
end
