defmodule MirrorNeuron.Runtime.JobMailbox.Attachment do
  @moduledoc false
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.JobData

  @chunk_bytes 1_048_576
  @max_bytes 67_108_864

  def valid?(%{"run_id" => run, "sha256" => digest, "size_bytes" => size} = ref),
    do:
      map_size(ref) == 3 and JobData.validate_id(run) == :ok and is_binary(digest) and
        Regex.match?(~r/\A[a-f0-9]{64}\z/, digest) and is_integer(size) and size in 1..@max_bytes

  def valid?(_), do: false

  # The storage binding comes from the physical run record on its owner.
  # The caller supplies neither a path nor an endpoint.
  def read_chunk(job, ref, offset, run_lookup \\ &MirrorNeuron.inspect_job/1) do
    with true <- valid?(ref) and is_integer(offset) and offset >= 0 and offset < ref["size_bytes"],
         {:ok, record} <- run_lookup.(ref["run_id"]),
         true <- record["stable_job_id"] == job,
         %{"submission_id" => submission, "run_id" => run} <-
           SharedStorage.run_data_ref(record),
         {:ok, directory} <- run_directory(submission, run),
         file = Path.join(directory, ref["sha256"] <> ".json"),
         size = ref["size_bytes"],
         {:ok, %{type: :regular, size: ^size}} <- File.lstat(file) do
      length = min(@chunk_bytes, size - offset)

      case File.open(file, [:read, :binary, :raw], &:file.pread(&1, offset, length)) do
        {:ok, {:ok, bytes}} when byte_size(bytes) == length ->
          {:ok, %{"offset" => offset, "data" => Base.encode64(bytes)}}

        _ ->
          {:error, :mailbox_unavailable}
      end
    else
      false -> {:error, :invalid_mailbox_request}
      _ -> {:error, :mailbox_unavailable}
    end
  end

  defp run_directory(submission, run) do
    Enum.reduce_while(
      ["submissions", submission, "outputs", "runs", run, "collaboration"],
      {:ok, SharedStorage.root()},
      fn component, {:ok, parent} ->
        path = Path.join(parent, component)

        case File.lstat(path) do
          {:ok, %{type: :directory}} -> {:cont, {:ok, path}}
          _ -> {:halt, {:error, :mailbox_unavailable}}
        end
      end
    )
  end
end
