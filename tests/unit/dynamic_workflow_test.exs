defmodule MirrorNeuron.Runtime.DynamicWorkflowTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.DynamicWorkflowSpec
  alias MirrorNeuron.Runtime.WorkflowLedger

  test "dynamic mode and enablement are opt-in and internally consistent" do
    assert DynamicWorkflowSpec.validation_errors(%{"mode" => "static_dag"}, []) == []

    assert DynamicWorkflowSpec.validation_errors(
             %{"mode" => "static_dag", "dynamic" => %{"enabled" => false}},
             []
           ) == []

    assert ["dynamic.enabled requires workflow mode dynamic_dag"] =
             DynamicWorkflowSpec.validation_errors(
               %{"mode" => "static_dag", "dynamic" => %{"enabled" => true}},
               []
             )

    assert ["dynamic_dag workflows require dynamic.enabled true"] =
             DynamicWorkflowSpec.validation_errors(%{"mode" => "dynamic_dag"}, [])
  end

  test "atomically replaces a fixed path and propagates revision and instance input" do
    state = running_state("replace_path")
    {state, controller_message} = start_controller(state)

    patch = %{
      "patch_id" => "evidence-gap-1",
      "base_revision" => 0,
      "region_id" => "research_followups",
      "operations" => [
        %{"op" => "remove_edge", "id" => "inspect_to_report"},
        %{
          "op" => "add_step",
          "id" => "followup_1",
          "template" => "followup_research",
          "with" => %{"query" => "primary source"}
        },
        %{
          "op" => "add_step",
          "id" => "verify_1",
          "template" => "verify_evidence",
          "with" => %{}
        },
        %{
          "op" => "add_edge",
          "id" => "inspect_to_followup",
          "from" => "inspect",
          "to" => "followup_1"
        },
        %{
          "op" => "add_edge",
          "id" => "followup_to_verify",
          "from" => "followup_1",
          "to" => "verify_1"
        },
        %{
          "op" => "add_edge",
          "id" => "verify_to_report",
          "from" => "verify_1",
          "to" => "report"
        }
      ],
      "attempt_id" => controller_message["headers"]["mn.workflow.attempt_id"]
    }

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        patch,
        "2026-07-29T10:00:01.000Z"
      )

    applied = Enum.find(events, &(&1.type == :workflow_graph_patch_applied))
    assert applied.graph_revision == 1
    assert applied.patch_id == "evidence-gap-1"
    refute inspect(applied) =~ "primary source"
    assert state["graph_revision"] == 1
    assert get_in(state, ["steps", "followup_1", "template_id"]) == "followup_research"

    completion = %{
      "step_id" => "inspect",
      "attempt_id" => controller_message["headers"]["mn.workflow.attempt_id"],
      "idempotency_key" => controller_message["headers"]["mn.workflow.idempotency_key"]
    }

    {_state, _events, actions} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_step_attempt_completed,
        completion,
        "2026-07-29T10:00:02.000Z"
      )

    assert [{:redeliver, "followup_1", "followup_worker", trigger}] = actions
    assert trigger["headers"]["mn.workflow.graph_revision"] == 1
    assert trigger["headers"]["mn.workflow.template_id"] == "followup_research"
    assert get_in(trigger, ["body", "_mn_step", "step_input"]) == %{"query" => "primary source"}
  end

  test "rejects a stale patch atomically and fails the requesting attempt" do
    state = running_state("replace_path")
    {state, _message} = start_controller(state)

    patch = %{
      "patch_id" => "stale",
      "base_revision" => 9,
      "region_id" => "research_followups",
      "operations" => [%{"op" => "remove_edge", "id" => "inspect_to_report"}]
    }

    {state, events, actions} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        patch,
        "2026-07-29T10:00:01.000Z"
      )

    assert Enum.any?(events, &(&1.type == :workflow_graph_patch_rejected))
    assert Enum.any?(events, &(&1.type == :workflow_step_failed))
    assert [{:fail_job, "inspect", _reason}] = actions
    assert state["graph_revision"] == 0
    assert Enum.any?(state["edges"], &(&1["id"] == "inspect_to_report"))
  end

  test "treats an exact duplicate patch id as a successful no-op" do
    state = running_state("replace_path")
    {state, _message} = start_controller(state)

    patch = %{
      "patch_id" => "no-change-1",
      "base_revision" => 0,
      "region_id" => "research_followups",
      "operations" => [
        %{"op" => "remove_edge", "id" => "inspect_to_report"},
        %{
          "op" => "add_edge",
          "id" => "inspect_to_report_revised",
          "from" => "inspect",
          "to" => "report"
        }
      ]
    }

    {state, first_events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        patch,
        "2026-07-29T10:00:01.000Z"
      )

    {replayed_state, replay_events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        patch,
        "2026-07-29T10:00:02.000Z"
      )

    assert Enum.any?(first_events, &(&1.type == :workflow_graph_patch_applied))
    assert Enum.any?(replay_events, &(&1.type == :workflow_graph_patch_replayed))
    assert replayed_state["graph_revision"] == 1
    assert replayed_state["edges"] == state["edges"]
  end

  test "checkpoint fanout checkpoints the controller and releases roots immediately" do
    state = running_state("checkpoint_fanout")
    {state, _message} = start_controller(state)

    patch = %{
      "patch_id" => "service-item-1",
      "base_revision" => 0,
      "region_id" => "service_work",
      "operations" => [
        %{
          "op" => "add_step",
          "id" => "followup_1",
          "template" => "followup_research",
          "with" => %{"record_id" => 7}
        },
        %{
          "op" => "add_edge",
          "id" => "controller_to_followup",
          "from" => "inspect",
          "to" => "followup_1"
        }
      ]
    }

    {state, events, actions} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        patch,
        "2026-07-29T10:00:01.000Z"
      )

    assert Enum.any?(events, &(&1.type == :workflow_graph_patch_applied))
    assert get_in(state, ["steps", "inspect", "status"]) == "waiting"
    assert [{:redeliver, "followup_1", "followup_worker", _trigger}] = actions
  end

  test "service fanout retires completed finite work into bounded history" do
    state = running_state("checkpoint_fanout")
    {state, _message} = start_controller(state)

    {state, _events, [{:redeliver, "followup_1", "followup_worker", trigger}]} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        service_patch(),
        "2026-07-29T10:00:01.000Z"
      )

    {state, [_started]} =
      WorkflowLedger.on_message_received(
        state,
        "followup_worker",
        trigger,
        "2026-07-29T10:00:02.000Z"
      )

    attempt = get_in(state, ["steps", "followup_1", "current_attempt"])

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "followup_worker",
        :workflow_step_completed,
        %{
          "step_id" => "followup_1",
          "attempt_id" => attempt["attempt_id"],
          "idempotency_key" => attempt["idempotency_key"]
        },
        "2026-07-29T10:00:03.000Z"
      )

    refute Map.has_key?(state["steps"], "followup_1")
    refute Map.has_key?(state["dynamic_patch_instances"], "service-item-1")
    assert [%{"patch_id" => "service-item-1", "steps" => [retired]}] = state["dynamic_history"]
    assert retired["status"] == "completed"
    assert Enum.any?(events, &(&1.type == :workflow_dynamic_steps_retired))
  end

  test "a controller checkpoint is accepted once and stale controller events are fenced" do
    state = running_state("checkpoint_fanout")
    {state, message} = start_controller(state)
    attempt_id = message["headers"]["mn.workflow.attempt_id"]

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_controller_checkpoint,
        %{"region_id" => "service_work", "attempt_id" => attempt_id},
        "2026-07-29T10:00:01.000Z"
      )

    assert Enum.any?(events, &(&1.type == :workflow_controller_checkpointed))
    assert get_in(state, ["steps", "inspect", "status"]) == "waiting"

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_controller_checkpoint,
        %{"region_id" => "service_work", "attempt_id" => attempt_id},
        "2026-07-29T10:00:02.000Z"
      )

    assert Enum.any?(events, &(&1.type == :workflow_step_stale_output_ignored))
    assert get_in(state, ["steps", "inspect", "status"]) == "waiting"
  end

  test "a rejected patch fences a late completion from the rejected attempt" do
    state = running_state("replace_path") |> put_in(["steps", "inspect", "max_attempts"], 2)
    {state, message} = start_controller(state)
    attempt_id = message["headers"]["mn.workflow.attempt_id"]

    {state, _events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        %{
          "patch_id" => "stale-retry",
          "base_revision" => 9,
          "region_id" => "research_followups",
          "operations" => [%{"op" => "remove_edge", "id" => "inspect_to_report"}],
          "attempt_id" => attempt_id
        },
        "2026-07-29T10:00:01.000Z"
      )

    assert get_in(state, ["steps", "inspect", "status"]) == "retry_wait"

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_step_completed,
        %{"step_id" => "inspect", "attempt_id" => attempt_id},
        "2026-07-29T10:00:02.000Z"
      )

    assert get_in(state, ["steps", "inspect", "status"]) == "retry_wait"
    assert Enum.any?(events, &(&1.type == :workflow_step_stale_output_ignored))
  end

  test "terminal dynamic instances do not consume the active-step limit" do
    state = running_state("replace_path") |> put_in(["dynamic_limits", "max_active_steps"], 1)
    {state, _message} = start_controller(state)

    {state, _events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        replace_path_patch("path-1", "followup_1", 0, remove_direct?: true),
        "2026-07-29T10:00:01.000Z"
      )

    state =
      state
      |> put_in(["steps", "followup_1", "status"], "completed")
      |> put_in(["steps", "followup_1", "attempt_count"], 1)

    {state, events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        replace_path_patch("path-2", "followup_2", 1),
        "2026-07-29T10:00:02.000Z"
      )

    assert state["graph_revision"] == 2
    assert Map.has_key?(state["steps"], "followup_2")
    assert Enum.any?(events, &(&1.type == :workflow_graph_patch_applied))
  end

  test "patches cannot rewrite started dynamic work or spoof the controller step" do
    state = running_state("replace_path")
    {state, _message} = start_controller(state)

    {state, _events, []} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        replace_path_patch("path-1", "followup_1", 0, remove_direct?: true),
        "2026-07-29T10:00:01.000Z"
      )

    state =
      state
      |> put_in(["steps", "followup_1", "status"], "running")
      |> put_in(["steps", "followup_1", "attempt_count"], 1)

    {state, events, _actions} =
      WorkflowLedger.on_agent_event(
        state,
        "inspect",
        :workflow_graph_patch,
        %{
          "patch_id" => "rewrite-started",
          "base_revision" => 1,
          "region_id" => "research_followups",
          "operations" => [%{"op" => "remove_edge", "id" => "followup_1_to_report"}]
        },
        "2026-07-29T10:00:02.000Z"
      )

    assert state["graph_revision"] == 1
    assert Enum.any?(state["edges"], &(&1["id"] == "followup_1_to_report"))
    assert Enum.any?(events, &(&1.type == :workflow_graph_patch_rejected))

    spoofed = running_state("replace_path")
    {spoofed, _message} = start_controller(spoofed)

    {spoofed, events, []} =
      WorkflowLedger.on_agent_event(
        spoofed,
        "report",
        :workflow_graph_patch,
        Map.put(
          replace_path_patch("spoof", "followup_1", 0, remove_direct?: true),
          "step_id",
          "inspect"
        ),
        "2026-07-29T10:00:03.000Z"
      )

    assert spoofed["graph_revision"] == 0
    assert Enum.any?(events, &(&1.type == :workflow_graph_patch_rejected))
  end

  defp replace_path_patch(patch_id, step_id, revision, opts \\ []) do
    operations =
      [
        %{
          "op" => "add_step",
          "id" => step_id,
          "template" => "followup_research",
          "with" => %{}
        },
        %{
          "op" => "add_edge",
          "id" => "inspect_to_#{step_id}",
          "from" => "inspect",
          "to" => step_id
        },
        %{
          "op" => "add_edge",
          "id" => "#{step_id}_to_report",
          "from" => step_id,
          "to" => "report"
        }
      ]

    operations =
      if Keyword.get(opts, :remove_direct?, false),
        do: [%{"op" => "remove_edge", "id" => "inspect_to_report"} | operations],
        else: operations

    %{
      "patch_id" => patch_id,
      "base_revision" => revision,
      "region_id" => "research_followups",
      "operations" => operations
    }
  end

  defp service_patch do
    %{
      "patch_id" => "service-item-1",
      "base_revision" => 0,
      "region_id" => "service_work",
      "operations" => [
        %{
          "op" => "add_step",
          "id" => "followup_1",
          "template" => "followup_research",
          "with" => %{"record_id" => 7}
        },
        %{
          "op" => "add_edge",
          "id" => "controller_to_followup",
          "from" => "inspect",
          "to" => "followup_1"
        }
      ]
    }
  end

  defp running_state(strategy) do
    manifest = manifest(strategy)

    nodes = [
      %{node_id: "inspect", config: %{}},
      %{node_id: "report", config: %{}},
      %{node_id: "followup_worker", config: %{}},
      %{node_id: "verify_worker", config: %{}}
    ]

    {state, []} = WorkflowLedger.new(manifest, nodes) |> WorkflowLedger.job_running()
    state
  end

  defp start_controller(state) do
    message = Message.new("job", "runtime", "inspect", "start", %{})
    decorated = WorkflowLedger.decorate_message(state, "inspect", message)

    {state, [_event]} =
      WorkflowLedger.on_message_received(
        state,
        "inspect",
        decorated,
        "2026-07-29T10:00:00.000Z"
      )

    {state, get_in(state, ["steps", "inspect", "last_message"])}
  end

  defp manifest("replace_path") do
    %Manifest{
      flow:
        base_flow(%{
          "regions" => [
            %{
              "id" => "research_followups",
              "strategy" => "replace_path",
              "controller" => "inspect",
              "exit" => "report",
              "templates" => ["followup_research", "verify_evidence"],
              "mutable_edges" => ["inspect_to_report"]
            }
          ]
        })
    }
  end

  defp manifest("checkpoint_fanout") do
    %Manifest{
      flow:
        base_flow(%{
          "regions" => [
            %{
              "id" => "service_work",
              "strategy" => "checkpoint_fanout",
              "controller" => "inspect",
              "templates" => ["followup_research"]
            }
          ]
        })
        |> put_in(["graph", "edges"], [])
    }
  end

  defp base_flow(dynamic_overrides) do
    %{
      "mode" => "dynamic_dag",
      "steps" => [
        %{
          "id" => "inspect",
          "run" => "inspect",
          "control" => %{"retry" => %{"max_attempts" => 1}}
        },
        %{"id" => "report", "run" => "report"}
      ],
      "graph" => %{
        "edges" => [
          %{
            "id" => "inspect_to_report",
            "from" => "inspect",
            "to" => "report",
            "accepts" => ["done"]
          }
        ]
      },
      "dynamic" =>
        Map.merge(
          %{
            "enabled" => true,
            "apply_at" => "between_steps",
            "templates" => %{
              "followup_research" => %{"run" => "followup_worker", "label" => "Follow-up"},
              "verify_evidence" => %{"run" => "verify_worker", "label" => "Verify"}
            }
          },
          dynamic_overrides
        )
    }
  end
end
