defmodule MirrorNeuron.Persistence.RedisStore.Keys do
  @moduledoc "Builds and parses namespaced persistence keys without changing their durable format."

  alias MirrorNeuron.Config

  def root_job_id_from_key(redis_key) do
    case namespaced_key_parts(redis_key) do
      ["job", job_id] -> [job_id]
      _ -> []
    end
  end

  def bundle_archive_ref_from_key(redis_key) do
    case namespaced_key_parts(redis_key) do
      ["bundle", fingerprint] -> [{fingerprint, redis_key}]
      _ -> []
    end
  end

  defp namespaced_key_parts(redis_key) when is_binary(redis_key) do
    prefix = namespace() <> ":"

    if String.starts_with?(redis_key, prefix) do
      redis_key
      |> String.replace_prefix(prefix, "")
      |> String.split(":")
    else
      []
    end
  end

  defp namespaced_key_parts(_redis_key), do: []

  def delivery_index_key(job_id), do: key("job", job_id, "delivery_keys")

  def key(part1), do: Enum.join([namespace(), part1], ":")

  def key(part1, part2), do: Enum.join([namespace(), part1, part2], ":")

  def key(part1, part2, part3), do: Enum.join([namespace(), part1, part2, part3], ":")

  def key(part1, part2, part3, part4),
    do: Enum.join([namespace(), part1, part2, part3, part4], ":")

  def key(part1, part2, part3, part4, part5),
    do: Enum.join([namespace(), part1, part2, part3, part4, part5], ":")

  def channel(part1, part2), do: Enum.join([namespace(), "channel", part1, part2], ":")

  def namespace,
    do: Config.string("MN_REDIS_NAMESPACE", :redis_namespace)
end
