defmodule MirrorNeuron.DynamicWorkflowCase do
  use ExUnit.CaseTemplate

  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Message
  alias MirrorNeuron.Runtime.WorkflowLedger

  using do
    quote do
      import MirrorNeuron.DynamicWorkflowCase
    end
  end

  def replace_path_patch(patch_id, step_id, revision, opts \\ []) do
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

  def service_patch do
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

  def running_state(strategy) do
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

  def start_controller(state) do
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

  def manifest("replace_path") do
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

  def manifest("checkpoint_fanout") do
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

  def base_flow(dynamic_overrides) do
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
