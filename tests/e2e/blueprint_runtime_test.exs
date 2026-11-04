defmodule MirrorNeuron.BlueprintRuntimeTest do
  use MirrorNeuron.RuntimeCase, async: false

  @moduletag :blueprint_runtime
  # Public cancellation can finish between two admission scans. Allow the
  # owner to observe terminal cleanup on its next tick before asserting handoff.
  @handoff_timeout 15_000

  alias MirrorNeuron.Grpc.Handlers.Job
  alias MirrorNeuron.Runtime.{EventBus, NodeAdmission, ScheduleDispatcher}
  alias Mirrorneuron.Job.V1.{CreateJobRequest, RunAdmissionRequest, RunRequest, StartRunRequest}

  @tag :mock_gpu
  test "pause holds a shared GPU allocation and cancellation hands only that capacity to a waiter",
       %{id: prefix} do
    # CPU and RAM fit all three Jobs. Only two 4 GiB slices fit on the mock GPU.
    gpu = %{
      "driver" => "cuda",
      "count" => 1,
      "sharing" => "shared",
      "reservation_memory_mb" => 4096
    }

    [alpha, beta, waiting] =
      for name <- ~w(alpha beta waiting), do: prepare(prefix <> name, 1, devices: [gpu])

    assert {:ok, %{"reservations" => claims, "queue" => []}} = NodeAdmission.snapshot()
    assert claims == %{}

    for job <- [alpha, beta] do
      assert %{"run_id" => run} = start(job)
      await_event(run, :job_running)
      await_event(run, :agent_message_received)
    end

    first = run(alpha)
    peer = run(beta)

    assert %{"mode" => "shared", "state" => "reserved", "gpu_count" => 1, "gpu_memory_mb" => 4096} =
             claim(first)

    assert claim(peer) == claim(first)
    {:ok, held} = NodeAdmission.snapshot()

    # A failed immediate start must leave the definition and the queue untouched.
    assert %{"status" => "runnable_later"} = check(waiting)
    denied = assert_raise GRPC.RPCError, fn -> start(waiting) end
    assert denied.status == GRPC.Status.resource_exhausted()
    assert {:ok, []} = MirrorNeuron.list_runs(waiting)
    assert {:ok, ^held} = NodeAdmission.snapshot()

    assert %{
             "status" => "queued",
             "run_id" => waiting_id,
             "admission" => %{"position" => 1, "queue_id" => queue_id}
           } =
             start(waiting, "enqueue_if_busy", "wait-on-owner")

    assert %{
             "status" => "queued",
             "run_id" => ^waiting_id,
             "admission" => %{"queue_id" => ^queue_id}
           } =
             start(waiting, "enqueue_if_busy", "wait-on-owner")

    assert %{"state" => "queued"} = claim(run(waiting))
    control = %RunRequest{run_id: first["run_id"]}
    assert %{"status" => pause} = Job.pause_run(control, nil) |> unpack()
    assert pause in ["paused", "pause_pending"]
    await_event(control.run_id, :job_paused)
    paused = run(alpha)
    assert paused["status"] == "paused"
    assert claim(paused) == claim(first)
    assert %{"status" => "runnable_now"} = check(alpha, control.run_id)
    assert run(waiting)["status"] == "queued"

    assert %{"status" => "resumed"} = Job.resume_run(control, nil) |> unpack()
    await_event(control.run_id, :job_resumed)
    resumed = run(alpha)
    assert resumed["status"] == "running"
    assert resumed["attempt_id"] == first["attempt_id"]
    assert claim(resumed) == claim(first)
    assert {:ok, retained} = NodeAdmission.snapshot()
    assert generations(retained) == generations(held)

    assert %{"status" => result} = Job.cancel_run(control, nil) |> unpack()
    assert result in ["cancelled", "cancellation_pending"]
    # No explicit reconcile or second start. The owner's wake/dispatch path must work.
    await_event(waiting_id, :job_running, @handoff_timeout)
    await_event(waiting_id, :agent_message_received)
    cancelled = run(alpha)
    assert cancelled["status"] == "cancelled"
    assert claim(cancelled) == %{"state" => "unreserved"}
    assert claim(run(waiting)) == claim(first)
    assert {:ok, final} = NodeAdmission.snapshot()
    assert final["queue"] == []
    assert generations(final)[peer["run_id"]] == generations(held)[peer["run_id"]]
    assert final["reservations"][waiting_id]["generation"] > held["generation"]
    still_running = run(beta)
    assert still_running["status"] == "running"
    assert claim(still_running) == claim(peer)

    # A late queue-only cancel cannot kill the newly running execution.
    stale =
      assert_raise GRPC.RPCError, fn ->
        Job.cancel_run(%RunRequest{run_id: waiting_id, queued_only: true}, nil)
      end

    assert stale.status == GRPC.Status.failed_precondition()
    assert run(waiting)["status"] == "running"
    assert {:ok, [%{"run_id" => ^waiting_id}]} = MirrorNeuron.list_runs(waiting)
  end

  @tag :mock_gpu
  test "an incompatible GPU request is rejected even with an explicit queue policy", %{id: id} do
    gpu = %{
      "driver" => "metal",
      "count" => 1,
      "sharing" => "shared",
      "reservation_memory_mb" => 4096
    }

    job = prepare(id, 1, devices: [gpu])
    assert %{"status" => "not_runnable"} = check(job)
    denied = assert_raise GRPC.RPCError, fn -> start(job, "enqueue_if_busy") end
    assert denied.status == GRPC.Status.failed_precondition()
    assert {:ok, []} = MirrorNeuron.list_runs(job)
    assert {:ok, %{"reservations" => claims, "queue" => []}} = NodeAdmission.snapshot()
    assert claims == %{}
  end

  test "a due batch occurrence queues once and can be cancelled without touching the holder",
       %{id: prefix} do
    holder = prepare(prefix <> "holder", 4)
    scheduled = prepare(prefix <> "scheduled", 2)
    later = prepare(prefix <> "later", 2)
    %{"run_id" => holder_id} = start(holder)
    await_event(holder_id, :job_running)
    {:ok, held} = NodeAdmission.snapshot()

    # Advance the dispatcher explicitly. Its background timer cannot see this
    # occurrence, so there is no sleep or race at the wall-clock boundary.
    due = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

    assert {:ok, schedule} =
             MirrorNeuron.create_job_schedule(scheduled, %{
               "kind" => "delayed",
               "run_at" => DateTime.to_iso8601(due)
             })

    assert {:ok, %{dispatched: 0}} =
             ScheduleDispatcher.process_due_schedules(DateTime.add(due, -1))

    assert {:ok, []} = MirrorNeuron.list_runs(scheduled)
    assert {:ok, %{dispatched: 1, failed: 0}} = ScheduleDispatcher.process_due_schedules(due)
    assert {:ok, %{dispatched: 0, failed: 0}} = ScheduleDispatcher.process_due_schedules(due)

    assert {:ok, [%{"run_id" => id, "status" => "queued"}]} = MirrorNeuron.list_runs(scheduled)

    assert {:ok, %{"dispatches" => [%{"run_id" => ^id, "action" => "queued"}]}} =
             MirrorNeuron.get_schedule(schedule["schedule_id"])

    request = %RunRequest{run_id: id, queued_only: true}
    queued = Job.get_run(request, nil) |> unpack()
    assert queued["admission"]["blocked_by"]["run_id"] == holder_id

    assert %{"run_id" => later_id, "admission" => %{"position" => 2}} =
             start(later, "enqueue_if_busy")

    # The resource_wait schedule is published asynchronously by the admission owner.
    assert %{"target_run_id" => ^id, "kind" => "resource_wait"} =
             await_schedule(
               queued["admission"]["queue_id"],
               System.monotonic_time(:millisecond) + 8_000
             )

    assert %{"run_id" => ^id, "status" => "cancelled"} = Job.cancel_run(request, nil) |> unpack()
    assert {:error, _} = MirrorNeuron.get_schedule(queued["admission"]["queue_id"])

    assert {:ok, [%{"run_id" => ^id, "status" => "cancelled"}]} =
             MirrorNeuron.list_runs(scheduled)

    cancelled = Job.get_run(request, nil) |> unpack()
    refute cancelled["started_at"]
    assert claim(cancelled) == %{"state" => "unreserved"}
    assert run(holder)["status"] == "running"
    assert {:ok, after_cancel} = NodeAdmission.snapshot()
    assert generations(after_cancel) == generations(held)
    assert [%{"run_id" => ^later_id}] = after_cancel["queue"]
    assert run(later)["admission"]["position"] == 1

    Job.cancel_run(%RunRequest{run_id: holder_id}, nil)
    await_event(later_id, :job_running, @handoff_timeout)
    assert run(later)["status"] == "running"
    assert %{"status" => "cancelled"} = Job.get_run(request, nil) |> unpack()
  end

  test "only the last service window pauses the Run, and reopening it resumes the same attempt",
       %{id: job} do
    prepare(job, 1, type: "service")
    %{"run_id" => run_id} = start(job)
    await_event(run_id, :job_running)
    original = run(job)
    assert %{"state" => "reserved"} = claim(original)

    [{short, first_end}, {_long, last_end}] =
      for duration <- [:timer.hours(1), :timer.hours(2)] do
        {:ok, %{"schedule_id" => schedule}} =
          MirrorNeuron.create_job_schedule(job, %{
            "kind" => "event",
            "trigger" => %{"event_type" => "open"},
            "window" => %{"duration_ms" => duration}
          })

        assert %{dispatched: 1} = MirrorNeuron.dispatch_schedule(schedule)

        assert {:ok,
                %{
                  "dispatches" => [
                    %{
                      "run_id" => ^run_id,
                      "action" => "already_running",
                      "window_end_at" => ends_at
                    }
                  ]
                }} = MirrorNeuron.get_schedule(schedule)

        {:ok, until, _} = DateTime.from_iso8601(ends_at)
        {schedule, until}
      end

    assert {:ok, %{windows_closed: 1}} = ScheduleDispatcher.process_due_schedules(first_end)
    assert run(job)["status"] == "running"
    assert {:ok, %{windows_closed: 1}} = ScheduleDispatcher.process_due_schedules(last_end)
    await_event(run_id, :job_paused)
    paused = run(job)
    assert paused["status"] == "paused"
    assert claim(paused) == claim(original)

    assert %{dispatched: 1} = MirrorNeuron.dispatch_schedule(short)
    await_event(run_id, :job_resumed)
    resumed = run(job)
    assert resumed["status"] == "running"
    assert resumed["attempt_id"] == original["attempt_id"]
    assert {:ok, [%{"run_id" => ^run_id}]} = MirrorNeuron.list_runs(job)
  end

  defp prepare(job, cores, opts \\ []) do
    manifest = %{
      "apiVersion" => "mn.workflow/v1",
      "kind" => "Workflow",
      "manifest_version" => "1.0",
      "type" => Keyword.get(opts, :type, "batch"),
      "graph_id" => "runtime_contract",
      "entrypoints" => ["ingress"],
      "initial_inputs" => %{"ingress" => [%{"source" => job}]},
      "policies" => %{
        "resource_allocation" => %{
          "mode" => "shared",
          "cpu_cores" => cores,
          "memory_mb" => 512,
          "devices" => Keyword.get(opts, :devices, [])
        }
      },
      "flow" => %{
        "nodes" => [
          %{
            "node_id" => "ingress",
            "agent_type" => "router",
            "role" => "root_coordinator",
            "config" => %{}
          }
        ],
        "edges" => []
      }
    }

    request = %CreateJobRequest{job_id: job, manifest_json: Jason.encode!(manifest)}

    assert %{"job_id" => ^job, "status" => "active", "run_count" => 0} =
             Job.create_job(request, nil) |> unpack()

    {:ok, _} = EventBus.subscribe("run-" <> job)
    job
  end

  defp start(job, policy \\ "start_now", key \\ "") do
    request = %StartRunRequest{
      job_id: job,
      run_id: "run-" <> job,
      admission_policy: policy,
      idempotency_key: key
    }

    Job.start_run(request, nil) |> unpack()
  end

  defp check(job, run_id \\ "") do
    Job.check_run_admission(%RunAdmissionRequest{job_id: job, run_id: run_id}, nil) |> unpack()
  end

  defp run(job) do
    id = "run-" <> job
    request = %RunRequest{run_id: id}

    assert %{"job_id" => ^job, "run_id" => ^id, "status" => status} =
             record = Job.get_run(request, nil) |> unpack()

    assert {:ok, %{"summary" => %{"job_id" => ^id, "status" => ^status}}} =
             MirrorNeuron.job_details(id, compact: true)

    record
  end

  defp unpack(response), do: Jason.decode!(response.result_json)
  defp claim(record), do: record["placement"]["reservation"]

  defp generations(ledger) do
    Map.new(ledger["reservations"], fn {id, held} -> {id, held["generation"]} end)
  end

  defp await_schedule(id, deadline) do
    case MirrorNeuron.get_schedule(id) do
      {:ok, schedule} ->
        schedule

      {:error, reason} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "queue schedule #{id} did not appear: #{inspect(reason)}"

        Process.sleep(20)
        await_schedule(id, deadline)
    end
  end

  defp await_event(id, type, timeout \\ 5_000) do
    assert_receive {:mirror_neuron_event, %{job_id: ^id, type: ^type}}, timeout
  end
end
