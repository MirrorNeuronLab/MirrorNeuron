defmodule MirrorNeuron.Runtime.JobMailboxTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.{Cluster.NodeAdapter, JobData, Runtime.JobMailbox}

  setup do
    root = Path.join(System.tmp_dir!(), "mn-inbox-#{System.unique_integer([:positive])}")
    previous = System.get_env("MN_JOB_DATA_ROOT")
    System.put_env("MN_JOB_DATA_ROOT", root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: System.put_env("MN_JOB_DATA_ROOT", previous),
        else: System.delete_env("MN_JOB_DATA_ROOT")
    end)

    jobs =
      for {job, blueprint, peer, role} <- [
            {"mgr", "code_verifier", "spec", "reliability_verifier"},
            {"spec", "reliability_verifier", "mgr", "code_verifier"}
          ],
          into: %{} do
        {:ok, _} = JobData.initialize(job)

        contract = %{
          "schema" => "mn.collaboration.group.v1",
          "delivery" => "mailbox",
          "topology" => "group",
          "protocol" => "verification.v1",
          "goalId" => "verify",
          "sameRuntime" => true,
          "maxMembers" => 5,
          "managerBlueprintId" => "code_verifier",
          "accepts" => [role],
          "goalKey" => "inputs.payload.goal",
          "commonGoalKey" => "inputs.payload.mission",
          "peersKey" => "inputs.payload.peers",
          "groupKey" => "inputs.payload.group"
        }

        payload = %{
          "goal" => "verify",
          "group" => "group1",
          "mission" => "Check changes",
          "peers" => [%{"jobId" => peer, "blueprintId" => role}]
        }

        {job,
         %{
           "job_id" => job,
           "blueprint_id" => blueprint,
           "owner_node" => to_string(NodeAdapter.self()),
           "manifest" => %{"mcp" => %{"mailbox" => contract}},
           "status" => "active",
           "resolved_configuration" => %{"inputs" => %{"payload" => payload}}
         }}
      end

    %{jobs: jobs}
  end

  defp invoke(jobs, job, tool, args),
    do: JobMailbox.execute(job, tool, args, &Map.fetch(jobs, &1))

  defp send_message(jobs, job, data), do: invoke(jobs, job, "send_mailbox_message", data)
  defp list(jobs, job, opts), do: invoke(jobs, job, "list_mailbox_messages", opts)

  defp ack(jobs, job, id),
    do: invoke(jobs, job, "acknowledge_mailbox_message", %{"message_id" => id})

  defp ref(run), do: %{"run_id" => run, "sha256" => String.duplicate("a", 64), "size_bytes" => 20}

  test "messages persist without executions and preserve order, retries, and recipient isolation",
       %{jobs: jobs} do
    note = %{"recipient_job_id" => "spec", "request_id" => "one", "subject" => "Review bounds"}
    assert {:ok, first} = send_message(jobs, "mgr", note)
    assert {:ok, ^first} = send_message(jobs, "mgr", note)

    assert {:error, :mailbox_request_conflict} =
             send_message(jobs, "mgr", %{note | "subject" => "Changed"})

    assert {:error, :mailbox_request_conflict} =
             send_message(
               jobs,
               "mgr",
               Map.merge(note, %{"kind" => "assignment", "attachment" => ref("manager-run")})
             )

    assert {:ok, second} = send_message(jobs, "mgr", %{note | "request_id" => "two"})

    assert {:ok, %{"items" => [^first], "next_after" => cursor}} =
             list(jobs, "spec", %{"limit" => 1})

    assert {:ok, %{"items" => [^second], "next_after" => nil}} =
             list(jobs, "spec", %{"after" => cursor})

    assert {:error, :mailbox_message_not_found} = ack(jobs, "mgr", first["id"])
    assert {:ok, handled} = ack(jobs, "spec", first["id"])
    assert {:ok, ^handled} = ack(jobs, "spec", first["id"])
    assert {:ok, %{"items" => [^second]}} = list(jobs, "spec", %{})

    assert {:ok, %{"items" => [^handled, ^second]}} =
             list(jobs, "spec", %{"include_acknowledged" => true})

    changed =
      put_in(
        jobs,
        ["spec", "resolved_configuration", "inputs", "payload", "mission"],
        "Another assignment"
      )

    assert {:ok, %{"items" => []}} = list(changed, "spec", %{})
    assert {:error, :mailbox_group_mismatch} = send_message(changed, "mgr", note)
    invalid = put_in(jobs, ["mgr", "manifest", "mcp", "mailbox", "peersKey"], nil)
    assert {:error, :mailbox_group_mismatch} = list(invalid, "mgr", %{})
    foreign = put_in(jobs, ["spec", "owner_node"], "other@node")

    assert {:error, {:job_data_owner_unavailable, "other@node"}} =
             send_message(foreign, "mgr", note)
  end

  test "mailbox groups accept old, new and unspecified placement on prepared Jobs", %{jobs: jobs} do
    args = %{"recipient_job_id" => "spec", "request_id" => "mixed", "subject" => "Review"}
    updated = put_in(jobs, ~w(mgr manifest mcp mailbox sameRuntime), false)
    assert {:ok, receipt} = send_message(updated, "mgr", args)
    updated = update_in(updated, ~w(spec manifest mcp mailbox), &Map.delete(&1, "sameRuntime"))
    assert {:ok, ^receipt} = send_message(updated, "mgr", args)
    malformed = put_in(updated, ~w(spec manifest mcp mailbox sameRuntime), "false")
    assert {:error, :mailbox_group_mismatch} = send_message(malformed, "mgr", args)
  end

  @tag :tmp_dir
  test "serves bounded evidence only from the producing Job's bound run directory", %{
    tmp_dir: root
  } do
    alias MirrorNeuron.Runtime.JobMailbox.Attachment
    env = "MN_RUNTIME_SHARED_STORAGE_ROOT"
    previous = System.get_env(env)
    System.put_env(env, root)

    on_exit(fn ->
      if previous, do: System.put_env(env, previous), else: System.delete_env(env)
    end)

    record = %{
      "stable_job_id" => "mgr",
      "workflow_run_id" => "logical",
      "manifest" => %{"metadata" => %{"mn_storage" => %{"submission_id" => "submission"}}}
    }

    lookup = fn "physical" -> {:ok, record} end

    directory =
      Path.join([
        root,
        "submissions",
        "submission",
        "outputs",
        "runs",
        "logical",
        "collaboration"
      ])

    File.mkdir_p!(directory)
    bytes = String.duplicate("x", 1_048_576) <> "tail"
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    file = Path.join(directory, digest <> ".json")
    File.write!(file, bytes)
    ref = %{"run_id" => "physical", "sha256" => digest, "size_bytes" => byte_size(bytes)}

    assert {:ok, %{"offset" => 0, "data" => first}} = Attachment.read_chunk("mgr", ref, 0, lookup)
    assert byte_size(Base.decode64!(first)) == 1_048_576

    assert {:ok, %{"offset" => 1_048_576, "data" => tail}} =
             Attachment.read_chunk("mgr", ref, 1_048_576, lookup)

    assert Base.decode64!(tail) == "tail"
    assert {:error, :invalid_mailbox_request} = Attachment.read_chunk("spec", ref, 0, lookup)

    assert {:error, :invalid_mailbox_request} =
             Attachment.read_chunk("mgr", ref, byte_size(bytes), lookup)

    assert {:error, :mailbox_unavailable} =
             Attachment.read_chunk("mgr", %{ref | "size_bytes" => 1}, 0, lookup)

    # Replacing an artifact with a link must not open another file of the same size.
    File.rename!(file, file <> ".other")
    File.ln_s!(file <> ".other", file)
    assert {:error, :mailbox_unavailable} = Attachment.read_chunk("mgr", ref, 0, lookup)
  end

  test "a full inbox preserves pending work and reuses only acknowledged slots", %{jobs: jobs} do
    note = %{"recipient_job_id" => "spec", "request_id" => "first", "subject" => "Review"}
    assert {:ok, first} = send_message(jobs, "mgr", note)
    {:ok, dir} = JobData.path("spec")

    rows =
      for seq <- 1..1024,
          do: %{
            first
            | "id" => String.pad_leading(Integer.to_string(seq, 16), 64, "0"),
              "sequence" => seq
          }

    File.write!(Path.join(dir, ".mn-collaboration-mailbox.json"), Jason.encode!(rows))
    assert {:error, :mailbox_full} = send_message(jobs, "mgr", %{note | "request_id" => "next"})
    assert {:ok, _} = ack(jobs, "spec", hd(rows)["id"])

    assert {:ok, %{"sequence" => 1025}} =
             send_message(jobs, "mgr", %{note | "request_id" => "next"})

    assert {:ok, %{"items" => [%{"sequence" => 2}]}} = list(jobs, "spec", %{"limit" => 1})
  end

  test "existing reciprocal legacy peers can exchange notes after contract refresh", %{jobs: jobs} do
    jobs =
      for {id, job} <- jobs, into: %{} do
        [peer] = get_in(job, ~w(resolved_configuration inputs payload peers))

        job =
          job
          |> put_in(~w(manifest mcp mailbox legacyPeerKey), "inputs.payload.peer")
          |> update_in(~w(manifest mcp mailbox), &Map.delete(&1, "managerBlueprintId"))
          |> update_in(
            ~w(resolved_configuration inputs payload),
            &Map.merge(&1, %{"group" => "", "peers" => [], "peer" => peer["jobId"]})
          )

        {id, job}
      end

    note = %{"recipient_job_id" => "spec", "request_id" => "one", "subject" => "Check"}
    assert {:ok, row} = send_message(jobs, "mgr", note)
    assert {:ok, %{"items" => [^row]}} = list(jobs, "spec", %{})
    changed = put_in(jobs, ~w(spec resolved_configuration inputs payload peer), "")
    assert {:error, :mailbox_group_mismatch} = send_message(changed, "mgr", note)
  end

  test "only a delivered suite assignment launches its addressed member", %{jobs: jobs} do
    alias MirrorNeuron.Runtime.JobMailbox.SuiteAssignment
    jobs = put_in(jobs, ~w(mgr manifest mcp blueprint), %{"coworker_type" => "suite"})

    task = %{
      "recipient_job_id" => "spec",
      "request_id" => "one",
      "kind" => "assignment",
      "subject" => "Check input",
      "attachment" => ref("mgr-run")
    }

    assert {:suite_assignment, row} = send_message(jobs, "mgr", task)
    assert {:suite_assignment, ^row} = send_message(jobs, "mgr", task)

    launch = fn job, id ->
      send(self(), {:launch, job, id})
      {:ok, %{}}
    end

    assert {:ok, ^row} = SuiteAssignment.start_delivered({:suite_assignment, row}, launch)
    id = row["id"]
    assert_received {:launch, "spec", ^id}
    assert {:ok, %{"items" => [^row]}} = list(jobs, "spec", %{"message_id" => id})

    assert {:ok, %{"items" => []}} =
             list(jobs, "spec", %{"message_id" => String.duplicate("0", 64)})

    assert {:ok, _} = ack(jobs, "spec", id)
    assert {:ok, %{"status" => "acknowledged"}} = send_message(jobs, "mgr", task)
    note = Map.merge(task, %{"kind" => "note", "request_id" => "note"})
    assert {:ok, _} = send_message(jobs, "mgr", note) |> SuiteAssignment.start_delivered(launch)

    assert {:error, :invalid_mailbox_request} =
             send_message(jobs, "mgr", Map.put(note, "launch_member", true))

    refute_received {:launch, _, _}
  end

  test "only a manager assigns and results bind to its original request", %{jobs: jobs} do
    task = %{
      "recipient_job_id" => "mgr",
      "request_id" => "one",
      "kind" => "assignment",
      "subject" => "Check input",
      "attachment" => ref("mgr-run")
    }

    assert {:error, :mailbox_group_mismatch} = send_message(jobs, "spec", task)
    assert {:ok, assignment} = send_message(jobs, "mgr", %{task | "recipient_job_id" => "spec"})

    retry = %{task | "recipient_job_id" => "spec", "attachment" => ref("manager-retry")}
    assert {:ok, ^assignment} = send_message(jobs, "mgr", retry)

    assert {:error, :mailbox_request_conflict} =
             send_message(jobs, "mgr", Map.put(retry, "text", "Changed"))

    assert {:error, :mailbox_message_not_found} =
             invoke(jobs, "spec", "acknowledge_mailbox_message", %{
               "message_id" => assignment["id"],
               "expected_kind" => "note"
             })

    result =
      %{task | "kind" => "result", "attachment" => ref("spec-run")}
      |> Map.put("reply_to", assignment["id"])

    assert {:error, :mailbox_message_not_found} =
             send_message(jobs, "spec", %{result | "reply_to" => String.duplicate("e", 64)})

    assert {:ok, first} = send_message(jobs, "spec", result)

    assert {:ok, ^first} =
             send_message(jobs, "spec", %{result | "attachment" => ref("retried-run")})

    assert {:ok, %{"items" => [^first]}} =
             list(jobs, "mgr", %{"kind" => "result", "reply_to" => assignment["id"]})
  end
end
