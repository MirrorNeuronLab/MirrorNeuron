defmodule MirrorNeuron.Runtime.JobMailbox.Storage do
  @moduledoc "Bounded, atomically replaced inbox in the durable recipient Job's data directory."
  alias MirrorNeuron.JobData

  @capacity 1024

  def list(job, scope, args) do
    limit = Map.get(args, "limit", 25)
    after_seq = Map.get(args, "after", 0)
    acknowledged = Map.get(args, "include_acknowledged", false)
    kind = args["kind"]
    reply = args["reply_to"]

    with true <- Map.keys(args) -- ~w(limit after include_acknowledged kind reply_to) == [],
         true <- is_integer(limit) and limit in 1..50 and is_integer(after_seq) and after_seq >= 0,
         true <- is_boolean(acknowledged) and kind in [nil, "assignment", "result", "note"],
         true <- is_nil(reply) or is_binary(reply),
         {:ok, _, rows} <- load(job) do
      page =
        rows
        |> Stream.filter(fn row ->
          row["scope"] == scope and row["sequence"] > after_seq and
            (acknowledged or row["status"] == "queued") and
            (is_nil(kind) or row["kind"] == kind) and (is_nil(reply) or row["reply_to"] == reply)
        end)
        |> Enum.take(limit + 1)

      items = Enum.take(page, limit)

      {:ok,
       %{
         "items" => items,
         "next_after" => if(length(page) > limit, do: List.last(items)["sequence"])
       }}
    else
      false -> {:error, :invalid_mailbox_request}
      error -> error
    end
  end

  def get(job, scope, id) do
    with {:ok, _, rows} <- load(job) do
      case Enum.find(rows, &(&1["id"] == id and &1["scope"] == scope)) do
        nil -> {:error, :mailbox_message_not_found}
        row -> {:ok, row}
      end
    end
  end

  def deliver(job, message) do
    with {:ok, path, rows} <- load(job) do
      case Enum.find(rows, &(&1["id"] == message["id"])) do
        nil ->
          append(path, rows, message)

        previous ->
          # Only the first completed result for an assignment is authoritative.
          # A retry may have produced equivalent evidence under a new physical run.
          if message["kind"] == "result" or equivalent?(previous, message),
            do: {:ok, previous},
            else: {:error, :mailbox_request_conflict}
      end
    end
  end

  defp equivalent?(%{"kind" => "assignment"} = previous, %{"kind" => "assignment"} = message) do
    # A retried manager can commit the same approved bytes under a new run.
    drop_run = fn row -> update_in(row["attachment"], &Map.delete(&1, "run_id")) end
    drop_run.(Map.drop(previous, ~w(created_at sequence status))) == drop_run.(message)
  end

  defp equivalent?(previous, message),
    do: Map.drop(previous, ~w(created_at sequence status)) == message

  def acknowledge(job, scope, id, expected_kind) do
    with {:ok, path, rows} <- load(job),
         index when is_integer(index) <-
           Enum.find_index(
             rows,
             &(&1["id"] == id and &1["scope"] == scope and
                 (is_nil(expected_kind) or &1["kind"] == expected_kind))
           ) do
      row = Enum.at(rows, index)

      if row["status"] == "acknowledged" do
        {:ok, row}
      else
        updated = Map.put(row, "status", "acknowledged")
        with :ok <- save(path, List.replace_at(rows, index, updated)), do: {:ok, updated}
      end
    else
      nil -> {:error, :mailbox_message_not_found}
      error -> error
    end
  end

  defp append(path, rows, message) do
    seq = if rows == [], do: 1, else: List.last(rows)["sequence"] + 1

    retained =
      if length(rows) < @capacity do
        rows
      else
        index =
          Enum.find_index(
            rows,
            &(&1["status"] == "acknowledged" or &1["scope"] != message["scope"])
          )

        if is_integer(index), do: List.delete_at(rows, index)
      end

    if retained do
      row =
        Map.merge(message, %{
          "sequence" => seq,
          "status" => "queued",
          "created_at" => MirrorNeuron.Runtime.timestamp()
        })

      with :ok <- save(path, retained ++ [row]), do: {:ok, row}
    else
      {:error, :mailbox_full}
    end
  end

  defp load(job) do
    with {:ok, dir} <- JobData.path(job),
         {:ok, %{type: :directory}} <- File.lstat(dir) do
      path = Path.join(dir, ".mn-collaboration-mailbox.json")

      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, path, []}

        {:ok, %{type: :regular, size: size}} when size <= 16_777_216 ->
          with {:ok, contents} <- File.read(path),
               {:ok, rows} when is_list(rows) and length(rows) <= @capacity <-
                 Jason.decode(contents),
               true <- Enum.all?(rows, &valid_stored?(&1, job)) do
            {:ok, path, rows}
          else
            _ -> {:error, :mailbox_unavailable}
          end

        _ ->
          {:error, :mailbox_unavailable}
      end
    else
      _ -> {:error, :mailbox_unavailable}
    end
  end

  defp valid_stored?(
         %{
           "recipient_job_id" => job,
           "id" => id,
           "scope" => scope,
           "sequence" => seq,
           "status" => status,
           "kind" => kind
         } = row,
         job
       ) do
    is_integer(seq) and seq > 0 and is_binary(id) and is_binary(scope) and
      is_binary(row["subject"]) and status in ["queued", "acknowledged"] and
      (kind == "note" or (kind in ["assignment", "result"] and is_map(row["attachment"])))
  end

  defp valid_stored?(_, _), do: false

  defp save(path, rows) do
    temp = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    write = fn file ->
      with :ok <- File.chmod(temp, 0o600), do: IO.binwrite(file, Jason.encode_to_iodata!(rows))
    end

    try do
      case File.open(temp, [:write, :binary, :exclusive, :sync], write) do
        {:ok, :ok} -> File.rename(temp, path)
        {:ok, error} -> error
        error -> error
      end
    after
      File.rm(temp)
    end
  end
end
