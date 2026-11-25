defmodule MirrorNeuron.Sandbox.WitServices do
  @moduledoc "Binds WIT imports to the physical execution and stable Job admitted by Core."
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.ModelServices.Commands
  alias MirrorNeuron.Runtime.Interactions
  alias MirrorNeuron.Runner.HostLocal.Context
  alias MirrorNeuron.Sandbox.Wasmtime
  alias MirrorNeuron.Sandbox.WitArtifacts, as: Artifacts

  def dispatch(config, opts, message) do
    execution = Keyword.fetch!(opts, :job_id)
    coordinator = Keyword.get(opts, :coordinator_node, node())
    workflow = Context.workflow_context(message)["run_id"] || Keyword.get(opts, :run_id)

    model =
      Map.take(
        config["environment"] || %{},
        ~w(MN_LLM_MODEL MN_LLM_PROVIDER MN_LLM_BACKEND MN_LLM_CONTEXT_SIZE MN_BLUEPRINT_FAKE_LLM)
      )

    fn key, args ->
      if coordinator == node() do
        call(execution, workflow, key, args, model)
      else
        :rpc.call(
          coordinator,
          __MODULE__,
          :call,
          [execution, workflow, key, args, model],
          if(key == "model.generate-json", do: model_timeout_ms() + 5_000, else: 100_000)
        )
      end
    end
  end

  def call(execution, workflow, key, args, model) do
    with {:ok, record} <- MirrorNeuron.inspect_job(execution),
         %{"submission_id" => submission, "run_id" => ^workflow} <-
           SharedStorage.run_data_ref(record),
         job when is_binary(job) <- record["stable_job_id"],
         true <- record["status"] not in ~w(failed cancelled completed stopped paused),
         {:ok, root} <-
           Artifacts.directory(SharedStorage.root(), ["submissions", submission], false),
         {:ok, dir} <- Artifacts.directory(root, ["outputs", "runs", workflow], true) do
      scope = %{"job_id" => job, "execution_id" => execution, "runtime_run_id" => workflow}

      case {key, args} do
        {"artifacts.publish", [refs]} when is_binary(refs) and byte_size(refs) <= 2_000_000 ->
          with {:ok, files} when is_map(files) <- Jason.decode(refs) do
            storage = get_in(record, ["manifest", "metadata", "mn_storage"])

            output =
              if Enum.any?(storage["output_copy"] || [], &(&1["layout"] in ["batch", "service"])),
                do: Path.join([root, "outputs", "user"])

            MirrorNeuron.Builtins.BlockEventPublication.publish_wit(
              dir,
              output,
              SharedStorage.root(),
              files
            )
          else
            _ -> {:error, :invalid_publication}
          end

        _ ->
          perform(key, args, scope, dir, model)
      end
    else
      _ -> {:error, :run_scope_unavailable}
    end
  end

  defp perform("artifacts.read", [path, hash], _, dir, _), do: Artifacts.read(dir, path, hash)

  defp perform("artifacts.commit", [path, kind, content], _, dir, _),
    do: Artifacts.commit(dir, path, kind, content)

  defp perform("artifacts.static-report", [path, hash, title], _, dir, _),
    do: Artifacts.static_report(dir, path, hash, title)

  defp perform("approvals.request", [args], scope, _, _)
       when is_binary(args) and byte_size(args) <= 24_000 do
    with {:ok, %{"request_id" => id, "prompt" => prompt, "expires_at" => expiry} = body} <-
           Jason.decode(args),
         true <-
           is_binary(id) and byte_size(id) in 1..180 and is_binary(prompt) and is_integer(expiry),
         true <-
           Map.keys(body) --
             ~w(request_id prompt summary expires_at markdown_review snapshot_id rules_digest review_revision) ==
             [] do
      options =
        for action <- ~w(approve revise reject),
            do: %{"id" => action, "action" => action, "label" => String.capitalize(action)}

      metadata =
        Map.merge(body, %{
          "decision_type" => "markdown_review",
          "interaction_kind" => "approval",
          "blocking" => true,
          "options" => options
        })

      record = %{
        "id" => human_id(scope, id),
        "scope" => scope,
        "kind" => "approval",
        "presentation" => %{
          "widget" => "confirmation",
          "title" => String.slice(prompt, 0, 240),
          "text" => prompt
        },
        "options" => options,
        "blocking" => true,
        "expires_at" => expiry,
        "metadata" => metadata
      }

      existing = Interactions.command(%{"op" => "get", "id" => record["id"]})

      case existing do
        {:ok, %{"scope" => ^scope, "metadata" => ^metadata} = found} -> {:ok, found}
        {:error, "not_found"} -> Interactions.command(%{"op" => "create", "record" => record})
        _ -> {:error, :approval_revision_mismatch}
      end
    else
      _ -> {:error, :invalid_approval_request}
    end
  end

  defp perform("approvals.status", [id], scope, _, _)
       when is_binary(id) and byte_size(id) in 1..180 do
    with {:ok, %{"scope" => ^scope} = record} <-
           Interactions.command(%{"op" => "get", "id" => human_id(scope, id)}),
         do: {:ok, record}
  end

  defp perform("model.generate-json", [system, input, schema], scope, _, model)
       when is_binary(system) and byte_size(system) <= 32_768 and is_binary(input) and
              byte_size(input) <= 100_000 and is_binary(schema) and byte_size(schema) <= 32_768 do
    with {:ok, _} <- Jason.decode(input),
         {:ok, spec} when is_map(spec) <- Jason.decode(schema),
         {:ok, %{"value" => value}} <-
           Commands.job_response_command(
             %{
               "kind" => "wit_model",
               "scope" => scope,
               "model_binding" => model,
               "system" => system,
               "input" => input,
               "schema" => spec
             },
             model_timeout_ms()
           ) do
      {:ok, Jason.encode!(value)}
    else
      _ -> {:error, :model_request_failed}
    end
  end

  defp perform("mailbox.list", [filters], scope, _, _) do
    with {:ok, filters} when is_map(filters) <- Jason.decode(filters),
         do: mailbox(scope, "list_mailbox_messages", filters)
  end

  defp perform("mailbox.send", [message], scope, dir, _) do
    with {:ok, %{"value" => value} = args} <- Jason.decode(message),
         true <-
           Map.keys(args) -- ~w(recipient_job_id kind request_id reply_to subject text value) ==
             [],
         encoded = value <> "\n",
         {:ok, _} <- Jason.decode(value),
         hash = Artifacts.digest(encoded),
         {:ok, ref} <- Artifacts.commit(dir, "collaboration/" <> hash <> ".json", "json", encoded) do
      attachment = %{
        "run_id" => scope["execution_id"],
        "sha256" => hash,
        "size_bytes" => ref["size_bytes"]
      }

      mailbox(
        scope,
        "send_mailbox_message",
        args |> Map.delete("value") |> Map.put("attachment", attachment)
      )
    else
      _ -> {:error, :invalid_mailbox_message}
    end
  end

  defp perform("mailbox.acknowledge", [id], scope, _, _),
    do: mailbox(scope, "acknowledge_mailbox_message", %{"message_id" => id})

  defp perform("mailbox.attachment", [id, field], scope, _, _)
       when field in ~w(attachment assignment_attachment) do
    with {:ok, %{"items" => [row]}} <-
           mailbox(scope, "list_mailbox_messages", %{"message_id" => id, "limit" => 1}),
         true <- row["id"] == id and row["recipient_job_id"] == scope["job_id"],
         %{"size_bytes" => size, "sha256" => digest}
         when is_integer(size) and size in 1..15_000_000 <- row[field],
         {:ok, data} <- chunks(scope, id, field, size, 0, []),
         true <- Artifacts.digest(data) == digest and String.valid?(data) do
      {:ok, data}
    else
      _ -> {:error, :invalid_mailbox_attachment}
    end
  end

  defp perform(_, _, _, _, _), do: {:error, :invalid_service_request}

  # First use may prepare model weights before the SDK starts its inference timer.
  # The runner still enforces the deadline of the enclosing step.
  defp model_timeout_ms, do: :timer.seconds(Wasmtime.max_compute_seconds())

  defp chunks(_, _, _, size, size, parts),
    do: {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}

  defp chunks(scope, id, field, size, offset, parts) do
    with {:ok, %{"offset" => ^offset, "data" => b64}} <-
           mailbox(scope, "read_mailbox_attachment", %{
             "message_id" => id,
             "field" => field,
             "offset" => offset
           }),
         {:ok, data} <- Base.decode64(b64),
         true <- byte_size(data) in 1..(size - offset) do
      chunks(scope, id, field, size, offset + byte_size(data), [data | parts])
    else
      _ -> {:error, :invalid_mailbox_attachment}
    end
  end

  defp mailbox(scope, tool, args) do
    request = %Mirrorneuron.Job.V1.JobMailboxRequest{
      job_id: scope["job_id"],
      tool: tool,
      arguments_json: Jason.encode!(args),
      version: 1
    }

    # Same routed mailbox path as the SDK, including mutual group membership and
    # cross-owner attachment verification. The caller cannot choose a sender.
    response = MirrorNeuron.Grpc.Handlers.Job.Mailbox.job_mailbox(request, nil)
    Jason.decode(response.result_json)
  end

  defp human_id(scope, id), do: "human-" <> Artifacts.digest(scope["execution_id"] <> ":" <> id)
end
