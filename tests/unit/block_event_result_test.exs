defmodule MirrorNeuron.BlockEventResultTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Builtins.BlockEventResult

  defmodule EventRunner do
    def run(_payload, config, opts) do
      send(config["test_owner"], {:event_runner, opts[:step_instance], opts[:agent_state]})
      {:ok, %{"exit_code" => 0, "stdout" => Jason.encode!(config["test_result"]), "stderr" => ""}}
    end
  end

  @tag :tmp_dir
  test "actual executor publishes only an accepted transition and repairs its output on replay",
       %{tmp_dir: root} do
    previous = System.get_env("MN_SHARED_STORAGE_ROOT")
    System.put_env("MN_SHARED_STORAGE_ROOT", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("MN_SHARED_STORAGE_ROOT", previous),
        else: System.delete_env("MN_SHARED_STORAGE_ROOT")
    end)

    submission = Path.join(root, "submission")
    run = Path.join(submission, "outputs/runs/physical-run")
    output = Path.join(submission, "outputs/user")

    file =
      common_file(
        run,
        "blocks/new/report.md",
        "# Accepted scene\n",
        "markdown",
        "mn.committed_bytes/v1"
      )

    view =
      common_file(run, "blocks/new/view.html", "<p>Scene</p>", "html", "mn.committed_bytes/v1")

    receipt = %{
      "schema_version" => "mn.publication.v1",
      "plan" => [
        %{
          "id" => "report",
          "path" => file["path"],
          "kind" => "markdown",
          "required" => true,
          "authoritative" => true,
          "mode" => nil,
          "content_revision" => file["sha256"]
        },
        %{
          "id" => "view",
          "path" => view["path"],
          "kind" => "html",
          "required" => false,
          "authoritative" => false,
          "mode" => nil,
          "content_revision" => view["sha256"]
        }
      ],
      "artifacts" => [
        %{"id" => "report", "reference" => file, "required" => true},
        %{"id" => "view", "reference" => view, "required" => false}
      ],
      "warnings" => []
    }

    receipt =
      common_file(
        run,
        "blocks/new/receipt.json",
        Jason.encode!(receipt),
        "publication_receipt",
        "mn.committed_json/v1"
      )

    publication = %{
      "schema_version" => "mn.published_files/v1",
      "files" => %{"reports/report.md" => file, "views/index.html" => view},
      "receipts" => [receipt],
      "warnings" => []
    }

    lease =
      start_supervised!(
        {MirrorNeuron.Execution.LeaseManager,
         name: :"event-publication-lease-#{System.unique_integer([:positive])}",
         capacities: %{"default" => 1}}
      )

    node = %{
      node_id: "monitor",
      config:
        Map.merge(config(), %{
          :runner_module => EventRunner,
          :lease_manager => lease,
          "test_owner" => self(),
          "test_result" => Map.put(payload(), "publication", publication),
          "environment" => %{
            "MN_JOB_SHARED_STORAGE_ROOT" => submission,
            "MN_JOB_OUTPUT_DIR" => output
          }
        })
    }

    {:ok, state} = MirrorNeuron.Builtins.Executor.init(node)

    context = %{
      job_id: "job",
      node: %{node_id: "monitor"},
      coordinator: self(),
      workflow: %{"run_id" => "physical-run"},
      bundle_root: root,
      manifest_path: Path.join(root, "manifest.json"),
      payloads_path: root
    }

    message = MirrorNeuron.Message.new("job", "source", "monitor", "tick", %{})
    File.mkdir_p!(output)
    File.write!(Path.join(output, "views"), "optional directory unavailable")

    assert {:ok, next, initial_actions} =
             MirrorNeuron.Builtins.Executor.handle_message(message, state, context)

    assert File.read!(Path.join(output, "reports/report.md")) == "# Accepted scene\n"

    assert_receive {:agent_event, "monitor", :block_publication_warning,
                    %{"artifact_id" => "views/index.html"}}

    File.write!(Path.join(output, "reports/report.md"), "# A newer accepted scene\n")
    stale = put_in(next.agent_state["reference"]["path"], "blocks/later/event-state.json")

    assert {:error, %{"retryable" => false}, failed} =
             MirrorNeuron.Builtins.Executor.handle_message(message, stale, context)

    assert failed.agent_state == stale.agent_state
    assert File.read!(Path.join(output, "reports/report.md")) == "# A newer accepted scene\n"

    File.rm!(Path.join(output, "reports/report.md"))
    File.rm!(Path.join(run, "reports/report.md"))
    File.rm!(Path.join(output, "views"))

    assert {:ok, repaired, repaired_actions} =
             MirrorNeuron.Builtins.Executor.handle_message(message, next, context)

    assert repaired.agent_state == next.agent_state
    assert File.read!(Path.join(output, "reports/report.md")) == "# Accepted scene\n"
    assert File.read!(Path.join(output, "views/index.html")) == "<p>Scene</p>"
    assert Enum.map(initial_actions, &elem(&1, 0)) == Enum.map(repaired_actions, &elem(&1, 0))
    refute_receive {:agent_event, "monitor", :block_publication_warning, _}, 0

    unexported = Path.join(submission, "outputs/unexported")

    config =
      node.config
      |> Map.put("artifact_handoff", %{
        "version" => "mn.artifact_handoff/v1",
        "export_outputs" => false
      })
      |> put_in(["environment", "MN_JOB_OUTPUT_DIR"], unexported)

    {:ok, private_state} = MirrorNeuron.Builtins.Executor.init(%{node | config: config})

    assert {:ok, _, _} =
             MirrorNeuron.Builtins.Executor.handle_message(message, private_state, context)

    refute File.exists?(unexported)
  end

  defp common_file(root, name, bytes, kind, version) do
    path = Path.join(root, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    %{
      "type" => "artifact_ref",
      "version" => version,
      "path" => name,
      "kind" => kind,
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      "size_bytes" => byte_size(bytes)
    }
  end

  test "actual executor applies typed state and emits only declared ports" do
    lease =
      start_supervised!(
        {MirrorNeuron.Execution.LeaseManager,
         name: :"event-lease-#{System.unique_integer([:positive])}", capacities: %{"default" => 1}}
      )

    node = %{
      node_id: "monitor",
      config:
        Map.merge(config(), %{
          :runner_module => EventRunner,
          :lease_manager => lease,
          "test_owner" => self(),
          "test_result" => payload(),
          "output_message_type" => "unexpected_default"
        })
    }

    {:ok, state} = MirrorNeuron.Builtins.Executor.init(node)

    context = %{
      job_id: "job",
      node: %{node_id: "monitor"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    message = MirrorNeuron.Message.new("job", "source", "monitor", "tick", %{})

    assert {:ok, next, actions} =
             MirrorNeuron.Builtins.Executor.handle_message(message, state, context)

    assert next.agent_state["reference"] == payload()["event_result"]["next"]

    assert [{:emit, "sample_ready", %{"sample" => 1}, options}] =
             Enum.filter(actions, &match?({:emit, _, _, _}, &1))

    assert options[:headers]["mn.idempotency_key"] == "block-event:delivery-1:0"
    expected_instance = "event:monitor:" <> MirrorNeuron.Message.id(message)
    assert_receive {:event_runner, ^expected_instance, %{}}

    assert {:ok, replayed, _} =
             MirrorNeuron.Builtins.Executor.handle_message(message, next, context)

    assert replayed.agent_state == next.agent_state
  end

  test "configured event executors reject ordinary output instead of silently dropping emissions" do
    lease =
      start_supervised!(
        {MirrorNeuron.Execution.LeaseManager,
         name: :"event-lease-#{System.unique_integer([:positive])}", capacities: %{"default" => 1}}
      )

    node = %{
      node_id: "monitor",
      config:
        Map.merge(config(), %{
          :runner_module => EventRunner,
          :lease_manager => lease,
          "test_owner" => self(),
          "test_result" => %{"outputs" => %{}, "events" => []}
        })
    }

    {:ok, state} = MirrorNeuron.Builtins.Executor.init(node)

    context = %{
      job_id: "job",
      node: %{node_id: "monitor"},
      coordinator: self(),
      bundle_root: "/tmp",
      manifest_path: "/tmp/manifest.json",
      payloads_path: "/tmp/payloads"
    }

    message = MirrorNeuron.Message.new("job", "source", "monitor", "tick", %{})

    assert {:error, %{"retryable" => false}, failed} =
             MirrorNeuron.Builtins.Executor.handle_message(message, state, context)

    assert failed.agent_state == %{}
  end

  defp reference(root, kind, file) do
    %{
      "type" => "artifact_ref",
      "version" => "mn.committed_json/v1",
      "kind" => kind,
      "path" => "blocks/#{root}/#{file}",
      "sha256" => String.duplicate("a", 64),
      "size_bytes" => 42
    }
  end

  defp config do
    %{
      "block_event" => %{
        "version" => "mn.block_events/v1",
        "ports" => %{"ready" => "sample_ready"},
        "event_types" => ["sampled"]
      }
    }
  end

  defp payload(previous \\ nil) do
    %{
      "events" => [%{"type" => "sampled", "payload" => %{"count" => 1}}],
      "outputs" => %{},
      "event_result" => %{
        "version" => "mn.block_events/v1",
        "delivery_key" => "delivery-1",
        "previous" => previous,
        "next" => reference("new", "block_event_state", "event-state.json"),
        "reference" => reference("new", "block_result", "result.json"),
        "emissions" => [%{"port" => "ready", "value" => %{"sample" => 1}}]
      }
    }
  end

  test "Core resolves declared ports and replay retains deterministic delivery keys" do
    assert {:ok, state, [message], [_event]} =
             BlockEventResult.interpret(payload(), %{}, config())

    assert message["type"] == "sample_ready"
    assert message["body"] == %{"sample" => 1}
    refute Map.has_key?(message, "to")
    assert message["headers"]["mn.idempotency_key"] == "block-event:delivery-1:0"
    assert {:ok, ^state, [^message], [_]} = BlockEventResult.interpret(payload(), state, config())
  end

  test "a transition can advance its exact prior state but never a later state" do
    old = reference("old", "block_event_state", "event-state.json")
    state = %{"version" => "mn.block_event_state/v1", "reference" => old}
    assert {:ok, next, _, _} = BlockEventResult.interpret(payload(old), state, config())
    assert next["reference"] != old
    later = put_in(state["reference"]["path"], "blocks/later/event-state.json")

    assert {:error, %{"retryable" => false}} =
             BlockEventResult.interpret(payload(old), later, config())
  end

  test "missing, unknown and mismatched protocol bindings reject" do
    assert {:error, _} = BlockEventResult.interpret(payload(), %{}, %{})

    assert {:error, _} =
             BlockEventResult.interpret(
               put_in(payload()["event_result"]["version"], "future"),
               %{},
               config()
             )

    assert {:error, _} = BlockEventResult.validate_config(%{"version" => "future"})

    assert {:error, _} =
             BlockEventResult.validate_config(
               put_in(config()["block_event"]["ports"]["ready"], "bad topic\n")
             )

    assert :ok = BlockEventResult.validate_config(config()["block_event"])
  end

  for fault <- ~w(port route complete event reference previous size path) do
    @fault fault
    test "invalid #{@fault} rejects the whole transition before state or actions apply" do
      value = payload()

      value =
        case @fault do
          "port" ->
            put_in(value["event_result"]["emissions"], [%{"port" => "unknown", "value" => %{}}])

          "route" ->
            put_in(value["event_result"]["emissions"], [
              %{"port" => "ready", "value" => %{}, "to" => "other"}
            ])

          "complete" ->
            Map.put(value, "complete_run", true)

          "event" ->
            put_in(value["events"], [%{"type" => "unknown", "payload" => %{}}])

          "reference" ->
            put_in(value["event_result"]["reference"]["path"], "blocks/different/result.json")

          "previous" ->
            put_in(
              value["event_result"]["previous"],
              reference("old", "block_event_state", "event-state.json")
            )

          "size" ->
            put_in(value["event_result"]["next"]["size_bytes"], -1)

          "path" ->
            put_in(value["event_result"]["next"]["path"], "blocks/../outside")
        end

      assert {:error, %{"retryable" => false}} = BlockEventResult.interpret(value, %{}, config())
    end
  end
end
