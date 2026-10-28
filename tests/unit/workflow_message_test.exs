defmodule MirrorNeuron.Runtime.WorkflowMessageTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Builtins.StepSource
  alias MirrorNeuron.Message
  alias MirrorNeuron.Runner.WorkflowEnvironment
  alias MirrorNeuron.Runtime.WorkflowMessage

  test "generated step source carries the ledger attempt into a block specialist" do
    incoming = incoming()
    config = %{"step_id" => "intake", "fields" => %{}, "output_message_type" => "started"}
    {:ok, source} = StepSource.init(%{config: config})
    {:ok, _, actions} = StepSource.handle_message(incoming, source, %{})
    {:emit, "started", payload, opts} = Enum.find(actions, &match?({:emit, _, _, _}, &1))

    outgoing =
      WorkflowMessage.build(
        state("intake__start"),
        incoming,
        "intake__worker",
        "started",
        payload,
        opts
      )

    assert Message.headers(outgoing) == Map.put(Message.headers(incoming), "mn.attempt_epoch", 3)

    env = WorkflowEnvironment.from_options(message: outgoing)
    assert env["MN_WORKFLOW_STEP_IDEMPOTENCY_KEY"] == "run:intake:1:input"
    assert is_binary(env["MN_WORKFLOW_IDEMPOTENCY_KEY"])
    assert env["MN_WORKFLOW_IDEMPOTENCY_KEY"] != ""
    assert env["MN_WORKFLOW_ATTEMPT_ID"] == "intake:attempt:1"
  end

  test "internal specialist, join and sink messages retain the logical attempt" do
    Enum.reduce(["intake__worker", "intake__other", "intake__end"], incoming(), fn target,
                                                                                   message ->
      next = WorkflowMessage.build(state(Message.to(message)), message, target, "done", %{})
      assert Message.headers(next)["mn.workflow.idempotency_key"] == "run:intake:1:input"
      assert Message.headers(next)["mn.workflow.attempt_id"] == "intake:attempt:1"
      assert Message.headers(next)["mn.workflow.graph_revision"] == 4
      next
    end)
  end

  test "crossing a step boundary clears the previous attempt for ledger admission" do
    outgoing = WorkflowMessage.build(state("intake__end"), incoming(), "next__start", "done", %{})
    headers = Message.headers(outgoing)
    assert headers["mn.workflow.step_id"] == "next"
    assert headers["mn.workflow.source_step_id"] == "intake"
    assert headers["mn.workflow.run_id"] == "run"

    for key <-
          ~w(attempt_id attempt deadline_at heartbeat_deadline_at idempotency_key graph_revision template_id region_id) do
      refute Map.has_key?(headers, "mn.workflow." <> key)
    end

    refute Map.has_key?(
             WorkflowEnvironment.from_options(message: outgoing),
             "MN_WORKFLOW_IDEMPOTENCY_KEY"
           )
  end

  test "child instance messages retain their attempt across template workers" do
    message =
      incoming()
      |> put_in(["headers", "mn.workflow.step_id"], "inspect:r1:task")
      |> put_in(["headers", "mn.workflow.template_id"], "intake")
      |> put_in(["headers", "mn.workflow.attempt_id"], "inspect:r1:task:attempt:1")
      |> put_in(["headers", "mn.workflow.idempotency_key"], "run:inspect:r1:task:1:input")

    outgoing =
      WorkflowMessage.build(state("intake__start"), message, "intake__worker", "work", %{})

    assert Message.headers(outgoing) == Map.put(Message.headers(message), "mn.attempt_epoch", 3)

    next = WorkflowMessage.build(state("intake__end"), outgoing, "next__start", "done", %{})
    assert Message.headers(next)["mn.workflow.step_id"] == "next"
    assert Message.headers(next)["mn.workflow.source_step_id"] == "inspect:r1:task"
    refute Map.has_key?(Message.headers(next), "mn.workflow.idempotency_key")
  end

  test "parallel specialists have independent keys and delivery replay keeps each key" do
    message = incoming()

    left =
      WorkflowMessage.build(state("intake__start"), message, "intake__worker", "work", %{},
        delivery_key: "edge-left"
      )

    right =
      WorkflowMessage.build(state("intake__start"), message, "intake__other", "work", %{},
        delivery_key: "edge-right"
      )

    replay =
      WorkflowMessage.build(
        state("intake__start"),
        put_in(message, ["envelope", "attempt"], 2),
        "intake__worker",
        "work",
        %{},
        delivery_key: "edge-left"
      )

    assert Message.id(replay) == Message.id(left)
    assert WorkflowEnvironment.invocation_key(replay) == WorkflowEnvironment.invocation_key(left)
    refute WorkflowEnvironment.invocation_key(left) == WorkflowEnvironment.invocation_key(right)

    refute WorkflowEnvironment.invocation_key(left) ==
             WorkflowEnvironment.invocation_key(
               put_in(left, ["envelope", "message_id"], "another-input")
             )

    refute WorkflowEnvironment.invocation_key(left) ==
             WorkflowEnvironment.invocation_key(
               put_in(left, ["headers", "mn.workflow.idempotency_key"], "run:intake:2:input")
             )
  end

  test "messages outside a workflow never receive a fabricated invocation key" do
    message = Message.new("job", "external", "worker", "work", %{}, message_id: "ordinary")
    assert WorkflowEnvironment.invocation_key(message) == nil
    outgoing = WorkflowMessage.build(state("worker"), message, "outside", "done", %{})
    assert Message.headers(outgoing) == %{"mn.attempt_epoch" => 3}
  end

  test "coordinator reports keep replay identity and isolate workflow and lease attempts" do
    state = state("intake__worker")
    first = incoming()

    report =
      WorkflowMessage.coordinator_report_id(state, first, "workflow_message_received", "received")

    replay = first |> put_in(["envelope", "attempt"], 2) |> Jason.encode!() |> Jason.decode!()

    assert WorkflowMessage.coordinator_report_id(
             state,
             replay,
             "workflow_message_received",
             "received"
           ) == report

    next_attempt = put_in(first, ["headers", "mn.workflow.attempt_id"], "intake:attempt:2")

    refute WorkflowMessage.coordinator_report_id(
             state,
             next_attempt,
             "workflow_message_received",
             "received"
           ) == report

    refute WorkflowMessage.coordinator_report_id(
             put_in(state.runtime_context.lease_epoch, 4),
             first,
             "workflow_message_received",
             "received"
           ) == report

    for {kind, key} <- [
          {"workflow_message_acked", "acked"},
          {"agent_event", 0},
          {"agent_event", 1}
        ] do
      refute WorkflowMessage.coordinator_report_id(state, first, kind, key) == report
    end
  end

  @tag :tmp_dir
  test "HostLocal receives the same scoped key as the Docker/OpenShell environment", %{
    tmp_dir: tmp_dir
  } do
    outgoing =
      WorkflowMessage.build(state("intake__start"), incoming(), "intake__worker", "work", %{})

    config = %{
      "workdir" => tmp_dir,
      "command" => [
        "/bin/sh",
        "-c",
        "printf '%s\\n%s\\n' \"$MN_WORKFLOW_IDEMPOTENCY_KEY\" \"$MN_WORKFLOW_STEP_IDEMPOTENCY_KEY\""
      ]
    }

    assert {:ok, result} =
             MirrorNeuron.Runner.HostLocal.run(%{}, config,
               message: outgoing,
               job_id: "job",
               agent_id: "intake__worker"
             )

    assert String.split(result["stdout"], "\n", trim: true) == [
             WorkflowEnvironment.invocation_key(outgoing),
             "run:intake:1:input"
           ]
  end

  defp incoming do
    Message.new("job", "runtime", "intake__start", "init", %{},
      message_id: "input",
      headers: %{
        "mn.workflow.run_id" => "run",
        "mn.workflow.step_id" => "intake",
        "mn.workflow.graph_revision" => 4,
        "mn.workflow.template_id" => "template",
        "mn.workflow.region_id" => "region",
        "mn.workflow.attempt_id" => "intake:attempt:1",
        "mn.workflow.attempt" => 1,
        "mn.workflow.idempotency_key" => "run:intake:1:input",
        "mn.workflow.deadline_at" => "2026-10-21T14:00:00Z",
        "mn.workflow.heartbeat_deadline_at" => "2026-10-21T13:59:00Z"
      }
    )
  end

  defp state(agent_id) do
    %{
      job_id: "job",
      node: %{node_id: agent_id},
      runtime_context: %{
        lease_epoch: 3,
        workflow_run_id: "run",
        workflow_agent_steps: %{
          "intake__start" => "intake",
          "intake__worker" => "intake",
          "intake__other" => "intake",
          "intake__end" => "intake",
          "next__start" => "next"
        }
      }
    }
  end
end
