defmodule MirrorNeuron.WorkflowLedgerCase do
  use ExUnit.CaseTemplate

  alias MirrorNeuron.Message
  alias MirrorNeuron.Manifest
  alias MirrorNeuron.Runtime.WorkflowLedger

  using do
    quote do
      import MirrorNeuron.WorkflowLedgerCase
    end
  end

  def reconcile(state, now) do
    {state, events, actions} = MirrorNeuron.Runtime.WorkflowLedger.reconcile(state, now)

    Enum.reduce(actions, {state, events, []}, fn
      {:inspect_step, id, token, agents}, {state, events, actions} ->
        {state, inspected, resolved} =
          MirrorNeuron.Runtime.WorkflowLedger.inspection_result(
            state,
            id,
            token,
            Map.new(agents, &{&1, "alive"}),
            now
          )

        {state, events ++ inspected, actions ++ resolved}

      action, {state, events, actions} ->
        {state, events, actions ++ [action]}
    end)
  end

  def dag_state(step_specs, edges) do
    manifest = dag_manifest(step_specs, edges)
    nodes = dag_nodes(step_specs)

    {state, []} = WorkflowLedger.new(manifest, nodes) |> WorkflowLedger.job_running(timestamp(0))
    state
  end

  def dag_manifest(step_specs, edges) do
    %Manifest{
      flow: %{
        "steps" => Enum.map(step_specs, &dag_step/1),
        "graph" => %{"edges" => edges}
      }
    }
  end

  def dag_nodes(step_specs) do
    Enum.map(step_specs, fn spec ->
      step_id = spec |> dag_step() |> Map.fetch!("id")
      %{node_id: step_id, config: %{"timeout_seconds" => 10, "max_attempts" => 1}}
    end)
  end

  def dag_step({id, trigger_rule, failure_policy}) do
    dag_step(id)
    |> Map.put("trigger_rule", trigger_rule)
    |> put_in(["control", "failure_policy"], failure_policy)
  end

  def dag_step({id, trigger_rule}), do: dag_step(id) |> Map.put("trigger_rule", trigger_rule)

  def dag_step(id) when is_binary(id) do
    %{
      "id" => id,
      "run" => id,
      "control" => %{
        "required" => true,
        "failure_policy" => "fail_workflow",
        "timeout_seconds" => 10,
        "retry" => %{"max_attempts" => 1, "backoff_seconds" => 0}
      }
    }
  end

  def edge(from, to) do
    %{
      "id" => "#{from}_to_#{to}",
      "from" => from,
      "to" => to,
      "accepts" => ["done"],
      "required" => true
    }
  end

  def receive_message(state, step_id) do
    message = Message.new("job", "upstream", step_id, "done", %{})
    receive_workflow_message(state, message)
  end

  def receive_workflow_message(state, message) do
    WorkflowLedger.on_message_received(state, Message.to(message), message, timestamp(0))
  end

  def complete_step(state, step_id) do
    {state, _events, _actions} =
      WorkflowLedger.on_agent_event(
        state,
        step_id,
        :workflow_step_attempt_completed,
        %{"step_id" => step_id, "status" => "completed"},
        timestamp(1)
      )

    state
  end

  def on_failed(state, step_id, reason) do
    WorkflowLedger.on_agent_failed(state, step_id, reason, timestamp(1))
  end

  def timestamp(offset_seconds) do
    "2026-06-02T16:00:#{offset_seconds |> Integer.to_string() |> String.pad_leading(2, "0")}.000Z"
  end

  def manifest(opts \\ []) do
    required? = Keyword.get(opts, :required?, true)

    %Manifest{
      flow: %{
        "steps" => [
          %{
            "id" => "step_a",
            "run" => "step_a",
            "label" => "Step A",
            "control" => %{
              "required" => required?,
              "failure_policy" => if(required?, do: "fail_workflow", else: "continue_partial"),
              "timeout_seconds" => 1,
              "retry" => %{
                "max_attempts" => if(required?, do: 2, else: 1),
                "backoff_seconds" => 1
              }
            }
          }
        ],
        "graph" => %{"edges" => []}
      }
    }
  end

  def runtime_nodes do
    [
      %{
        node_id: "step_a",
        config: %{
          "timeout_seconds" => 1,
          "beacon_timeout_ms" => 1_000,
          "max_attempts" => 2,
          "retry_backoff_ms" => 1_000
        }
      }
    ]
  end

  def join_manifest do
    %Manifest{
      flow: %{
        "steps" => [
          %{
            "id" => "step_a",
            "run" => "step_a",
            "label" => "Step A",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 5,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 1}
            }
          },
          %{
            "id" => "join_step",
            "run" => "join_step",
            "label" => "Join Step",
            "control" => %{
              "required" => true,
              "failure_policy" => "fail_workflow",
              "timeout_seconds" => 5,
              "retry" => %{"max_attempts" => 1, "backoff_seconds" => 1}
            }
          }
        ],
        "graph" => %{
          "edges" => [
            %{
              "id" => "step_a_to_join_step",
              "from" => "step_a",
              "to" => "join_step",
              "event" => "a_done",
              "accepts" => ["done"],
              "required" => true
            }
          ]
        }
      }
    }
  end

  def join_runtime_nodes do
    [
      %{node_id: "step_a", config: %{"timeout_seconds" => 5}},
      %{node_id: "join_step", config: %{"timeout_seconds" => 5}}
    ]
  end
end
