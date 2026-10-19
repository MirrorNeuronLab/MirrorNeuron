defmodule MirrorNeuron.Runtime.RunStartRequestTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runtime.RunStartRequest

  defmodule Store do
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{requests: %{}, runs: %{}, fail: false} end, name: __MODULE__)

    def fetch_run_start_request(id), do: Agent.get(__MODULE__, &fetch(&1.requests, id))
    def fetch_job(id), do: Agent.get(__MODULE__, &fetch(&1.runs, id))
    def execution_exists?(id), do: {:ok, Agent.get(__MODULE__, &Map.has_key?(&1.runs, id))}
    def put_run(id, run), do: Agent.update(__MODULE__, &put_in(&1, [:runs, id], run))
    def fail_next_write, do: Agent.update(__MODULE__, &%{&1 | fail: true})

    def persist_run_start_request(id, record) do
      Agent.get_and_update(__MODULE__, fn state ->
        if state.fail,
          do: {{:error, :unavailable}, %{state | fail: false}},
          else: {{:ok, record}, put_in(state, [:requests, id], record)}
      end)
    end

    defp fetch(values, id),
      do: if(Map.has_key?(values, id), do: {:ok, values[id]}, else: {:error, :not_found})
  end

  setup do
    start_supervised!(Store)
    :ok
  end

  defp run(start, payload \\ {"run-1", "{}", false}) do
    RunStartRequest.run("job-1", "request-1", payload, start, Store, fn _id, callback ->
      callback.()
    end)
  end

  test "a durable receipt replays after its request process exits without a PID" do
    assert {:ok, first} =
             Task.async(fn ->
               run(fn id, _ -> {:ok, %{run_id: id, status: "queued", pid: self()}} end)
             end)
             |> Task.await()

    assert first == %{"run_id" => "run-1", "status" => "queued"}
    assert {:ok, ^first} = run(fn _, _ -> flunk("duplicate start") end)

    assert {:error, :idempotency_key_reused} =
             run(fn _, _ -> flunk("changed request") end, {"other", "{}", false})
  end

  test "reconciles a run committed before the receipt write failed" do
    assert {:error, :unavailable} =
             run(fn id, identity ->
               Store.put_run(id, %{
                 "job_id" => id,
                 "stable_job_id" => "job-1",
                 "status" => "running",
                 "manifest" => %{"metadata" => %{"run_start_request" => identity}}
               })

               Store.fail_next_write()
               {:ok, %{run_id: id, status: "pending"}}
             end)

    assert {:ok, %{"run_id" => "run-1", "status" => "running", "action" => "reconciled"}} =
             run(fn _, _ -> flunk("a committed run cannot start twice") end)
  end

  test "persists identity before starting and fails closed if storage is unavailable" do
    Store.fail_next_write()
    assert {:error, :unavailable} = run(fn _, _ -> flunk("unrecorded request started") end)
  end

  test "cannot reconcile a different request's explicit run ID" do
    Store.put_run("run-1", %{"stable_job_id" => "job-1", "manifest" => %{"metadata" => %{}}})
    assert {:error, :run_already_exists} = run(fn _, _ -> flunk("existing run replaced") end)
  end

  test "keyed generated identities survive retry before any run was committed" do
    parent = self()

    assert {:error, :unavailable} =
             run(
               fn id, identity ->
                 send(parent, {id, identity})
                 {:error, :unavailable}
               end,
               {"", "{}", false}
             )

    assert_receive {id, identity}

    assert {:ok, %{"run_id" => ^id}} =
             run(
               fn retry_id, retry_identity ->
                 assert retry_id == id
                 assert retry_identity == identity
                 {:ok, %{run_id: retry_id}}
               end,
               {"", "{}", false}
             )
  end
end
