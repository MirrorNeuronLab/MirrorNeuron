defmodule MirrorNeuron.Runtime.DynamicWorkflow.PatchesTest do
  use MirrorNeuron.DynamicWorkflowCase, async: true

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
end
