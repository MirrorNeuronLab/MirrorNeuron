defmodule MirrorNeuron.JobId do
  @moduledoc false

  @hash_length 8

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
