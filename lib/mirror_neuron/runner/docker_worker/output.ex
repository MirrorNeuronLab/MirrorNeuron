defmodule MirrorNeuron.Runner.DockerWorker.Output do
  @moduledoc "Bounded diagnostic tails and captured command output."

  def compact_output_tail(output, limit \\ 1200) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.take(-20)
    |> Enum.join("\n")
    |> String.trim()
    |> truncate_tail(limit)
  end

  defp truncate_tail(text, limit) when byte_size(text) <= limit, do: text

  defp truncate_tail(text, limit) do
    marker = "[truncated]\n"
    keep = max(limit - byte_size(marker), 0)
    start = max(byte_size(text) - keep, 0)
    marker <> binary_part(text, start, min(keep, byte_size(text) - start))
  end

  def append_output(chunks, bytes, data, max_output_bytes) do
    cond do
      bytes >= max_output_bytes ->
        {chunks, bytes + byte_size(data)}

      bytes + byte_size(data) <= max_output_bytes ->
        {[data | chunks], bytes + byte_size(data)}

      true ->
        remaining = max(max_output_bytes - bytes, 0)
        truncated = binary_part(data, 0, remaining) <> "\n[truncated by docker worker output cap]"
        {[truncated | chunks], bytes + byte_size(data)}
    end
  end

  def sanitize_result(result) do
    MirrorNeuron.Runner.Result.sanitize(result)
  end
end
