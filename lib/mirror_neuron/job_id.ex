defmodule MirrorNeuron.JobId do
  @moduledoc false

  @hash_length 8
  @legacy_pattern ~r/^(.+)-\d{10,}-([a-f0-9]{8,})$/

  def generate(graph_id) do
    hash =
      :crypto.hash(
        :sha256,
        "#{graph_id}:#{System.system_time(:nanosecond)}:#{random_token()}"
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, @hash_length)

    "#{graph_initials(graph_id)}-#{hash}"
  end

  def legacy?(job_id) when is_binary(job_id), do: Regex.match?(@legacy_pattern, job_id)
  def legacy?(_job_id), do: false

  def compact_legacy(job_id) when is_binary(job_id) do
    case Regex.run(@legacy_pattern, job_id) do
      [_, graph_id, hash] ->
        {:ok, "#{graph_initials(graph_id)}-#{String.slice(hash, 0, @hash_length)}"}

      _ ->
        :error
    end
  end

  def compact_legacy(_job_id), do: :error

  def graph_initials(graph_id) do
    graph_id
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> case do
      "" -> "job"
      initials -> initials
    end
  end

  defp random_token do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
