defmodule MirrorNeuron.JobId do
  @moduledoc false

  @hash_length 8

  def generate(graph_id) do
    "#{graph_initials(graph_id)}-#{short_hash(graph_id)}"
  end

  def generate_run(job_id) do
    prefix =
      case Regex.run(~r/\Ajob_([a-z0-9]+)-[a-f0-9]{8}\z/, to_string(job_id)) do
        [_, initials] -> initials
        nil -> graph_initials(job_id)
      end

    "run_#{prefix}-#{short_hash(job_id)}"
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

  defp short_hash(value) do
    :crypto.hash(
      :sha256,
      "#{value}:#{System.system_time(:nanosecond)}:#{random_token()}"
    )
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end

  defp random_token do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
