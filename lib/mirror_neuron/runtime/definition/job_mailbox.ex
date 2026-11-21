defmodule MirrorNeuron.Runtime.JobMailbox do
  @moduledoc "Addressed, asynchronous communication between mutually configured stable Jobs."
  alias MirrorNeuron.JobData
  alias MirrorNeuron.Runtime.JobMailbox.Storage
  alias MirrorNeuron.Runtime.StableJob.{Records, StartGate}

  def call(job, tool, args) when is_map(args) do
    ids = if tool == "send_mailbox_message", do: [job, args["recipient_job_id"]], else: [job]

    if Enum.all?(ids, &(JobData.validate_id(&1) == :ok)) do
      # Acquire both definition/data gates in the same order for opposite-direction sends.
      operation = fn -> execute(job, tool, args, &MirrorNeuron.get_job/1) end

      ids
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce(operation, fn id, inner ->
        fn -> StartGate.with_start_gate(id, inner) end
      end)
      |> then(& &1.())
    else
      {:error, :invalid_mailbox_request}
    end
  end

  def execute(job, tool, args, lookup) do
    with {:ok, definition} <- lookup.(job),
         :ok <- Records.ensure_owner_node(definition),
         {:ok, group} <- group(definition, lookup) do
      case {tool, args} do
        {"list_mailbox_messages", _} ->
          Storage.list(job, group.scope, args)

        {"acknowledge_mailbox_message", %{"message_id" => id}} ->
          if Map.keys(args) -- ~w(message_id expected_kind) == [] and
               args["expected_kind"] in [nil, "note", "assignment", "result"] do
            Storage.acknowledge(job, group.scope, id, args["expected_kind"])
          else
            {:error, :invalid_mailbox_request}
          end

        {"send_mailbox_message", _} ->
          send_message(group, args, lookup)

        _ ->
          {:error, :invalid_mailbox_request}
      end
    end
  end

  defp group(%{"manifest" => %{"mcp" => %{"mailbox" => c}}} = job, lookup) when is_map(c) do
    with true <- job["status"] == "active" and c["delivery"] == "mailbox",
         true <- valid_contract?(c),
         config when is_map(config) <- job["resolved_configuration"] || %{},
         payload when is_map(payload) <- get_in_payload(config),
         read = fn key ->
           Map.get(payload, String.replace_prefix(c[key], "inputs.payload.", ""))
         end,
         {:ok, group, peers} <- membership(job, c, read, lookup),
         true <- is_list(peers) and length(peers) < c["maxMembers"] and Enum.all?(peers, &peer?/1) do
      own = {job["job_id"], job["blueprint_id"]}
      members = Enum.sort([own | Enum.map(peers, &{&1["jobId"], &1["blueprintId"]})])
      goal = read.("commonGoalKey")

      configured =
        valid_id?(group) and read.("goalKey") == c["goalId"] and is_binary(goal) and
          String.trim(goal) != ""

      manager = c["managerBlueprintId"]

      valid_members =
        length(Enum.uniq_by(members, &elem(&1, 0))) == length(members) and
          Enum.all?(peers, &(&1["blueprintId"] in c["accepts"])) and
          (is_nil(manager) or
             (Enum.count(members, &(elem(&1, 1) == manager)) == 1 and
                length(Enum.uniq_by(members, &elem(&1, 1))) == length(members)))

      scope =
        if configured and valid_members,
          do: hash({c["protocol"], group, c["goalId"], goal, manager, members})

      {:ok,
       %{
         job: elem(own, 0),
         blueprint: elem(own, 1),
         owner: job["owner_node"],
         id: group,
         scope: scope,
         members: members,
         manager: manager
       }}
    else
      _ -> {:error, :mailbox_group_mismatch}
    end
  end

  defp group(_, _), do: {:error, :mailbox_group_mismatch}

  defp membership(job, c, read, lookup) do
    group = read.("groupKey")
    peers = read.("peersKey") || []
    legacy = c["legacyPeerKey"] && read.("legacyPeerKey")

    if group in [nil, ""] and peers == [] and legacy not in [nil, ""] do
      with :ok <- JobData.validate_id(legacy),
           {:ok, other} <- lookup.(legacy) do
        pair = [job["job_id"], legacy] |> Enum.sort() |> Enum.join(":")
        id = :crypto.hash(:sha256, pair) |> Base.encode16(case: :lower) |> binary_part(0, 24)
        {:ok, "pair-" <> id, [%{"jobId" => legacy, "blueprintId" => other["blueprint_id"]}]}
      end
    else
      {:ok, group, peers}
    end
  end

  defp get_in_payload(%{"inputs" => %{"payload" => payload}}), do: payload
  defp get_in_payload(_), do: %{}

  defp valid_contract?(c) do
    keys =
      Enum.map(~w(goalKey groupKey commonGoalKey peersKey), &c[&1]) ++
        if(Map.has_key?(c, "legacyPeerKey"), do: [c["legacyPeerKey"]], else: [])

    c["schema"] == "mn.collaboration.group.v1" and c["sameRuntime"] == true and
      c["topology"] == "group" and c["maxMembers"] in 2..16 and
      valid_id?(c["protocol"]) and valid_id?(c["goalId"]) and
      (is_nil(c["managerBlueprintId"]) or valid_id?(c["managerBlueprintId"])) and
      is_list(c["accepts"]) and length(c["accepts"]) in 1..20 and
      Enum.all?(c["accepts"], &valid_id?/1) and
      length(Enum.uniq(keys)) == length(keys) and
      Enum.all?(
        keys,
        &(is_binary(&1) and Regex.match?(~r/\Ainputs\.payload\.[A-Za-z0-9_]{1,80}\z/, &1))
      )
  end

  defp peer?(%{"jobId" => id, "blueprintId" => role} = p),
    do: map_size(p) == 2 and JobData.validate_id(id) == :ok and valid_id?(role)

  defp peer?(_), do: false

  defp send_message(from, args, lookup) do
    target = args["recipient_job_id"]
    kind = Map.get(args, "kind", "note")

    with true <-
           Map.keys(args) -- ~w(recipient_job_id request_id kind subject text attachment reply_to) ==
             [],
         true <-
           valid_id?(args["request_id"]) and byte_size(args["request_id"]) <= 128 and
             bounded?(args["subject"], 200) and
             bounded?(Map.get(args, "text", ""), 2000, true) and attachment?(args["attachment"]),
         true <-
           kind in ~w(note assignment result) and (kind == "note" or is_map(args["attachment"])),
         :ok <-
           permit(
             not is_nil(from.scope) and target != from.job and
               List.keymember?(from.members, target, 0)
           ),
         {:ok, definition} <- lookup.(target),
         {:ok, to} <- group(definition, lookup),
         :ok <- permit(to.scope == from.scope and to.owner == from.owner),
         {:ok, correlation} <- correlation(kind, from, to, args["reply_to"]) do
      id =
        if kind == "result",
          do: hash({from.scope, from.job, :result, args["reply_to"]}),
          else: hash({from.scope, from.job, target, args["request_id"]})

      message =
        Map.merge(Map.take(args, ~w(subject attachment reply_to)), %{
          "text" => Map.get(args, "text", ""),
          "id" => id,
          "group_id" => from.id,
          "scope" => from.scope,
          "kind" => kind,
          "sender_job_id" => from.job,
          "sender_blueprint_id" => from.blueprint,
          "recipient_job_id" => target
        })

      Storage.deliver(target, Map.merge(message, correlation))
    else
      false -> {:error, :invalid_mailbox_request}
      error -> error
    end
  end

  defp correlation("note", _, _, nil), do: {:ok, %{}}

  defp correlation("assignment", from, to, nil) do
    with :ok <- permit(from.manager == from.blueprint and to.blueprint != from.manager),
         do: {:ok, %{}}
  end

  defp correlation("result", from, to, reply) when is_binary(reply) do
    with :ok <- permit(to.manager == to.blueprint),
         {:ok, original} <- Storage.get(from.job, from.scope, reply),
         :ok <- permit(original["kind"] == "assignment" and original["sender_job_id"] == to.job) do
      {:ok, %{"assignment_attachment" => original["attachment"]}}
    end
  end

  defp correlation(_, _, _, _), do: {:error, :invalid_mailbox_request}

  defp attachment?(nil), do: true

  defp attachment?(%{"run_id" => run, "sha256" => digest, "size_bytes" => size} = ref),
    do:
      map_size(ref) == 3 and JobData.validate_id(run) == :ok and is_binary(digest) and
        Regex.match?(~r/\A[a-f0-9]{64}\z/, digest) and is_integer(size) and size in 1..67_108_864

  defp attachment?(_), do: false
  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9_.-]{1,160}\z/, id)

  defp bounded?(s, max, empty \\ false),
    do: is_binary(s) and byte_size(s) <= max and (empty or String.trim(s) != "")

  defp hash(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp permit(true), do: :ok
  defp permit(false), do: {:error, :mailbox_group_mismatch}
end
