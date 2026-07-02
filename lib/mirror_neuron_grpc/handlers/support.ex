defmodule MirrorNeuron.Grpc.Handlers.Support do
  @moduledoc false

  @interface_version 1

  def interface_version, do: @interface_version

  def write_payloads(_payloads_dir, nil), do: :ok

  def write_payloads(payloads_dir, payloads) do
    Enum.reduce_while(payloads, :ok, fn {path, content}, :ok ->
      case MirrorNeuron.Grpc.Validation.safe_payload_path(payloads_dir, path) do
        {:ok, full_path} ->
          File.mkdir_p!(Path.dirname(full_path))
          File.write!(full_path, content)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def request_bundle_dir(manifest_json, payloads) do
    bundle_id = "bundle_#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), bundle_id)
    payloads_dir = Path.join(tmp_dir, "payloads")

    File.mkdir_p!(payloads_dir)
    File.write!(Path.join(tmp_dir, "manifest.json"), manifest_json)

    with :ok <- write_payloads(payloads_dir, payloads) do
      {:ok, tmp_dir}
    end
  end

  def versioned_json(value) when is_map(value) do
    value
    |> Map.put_new("version", @interface_version)
    |> Jason.encode!()
  end

  def versioned_json(value), do: Jason.encode!(value)

  def decode_json_map(nil), do: %{}
  def decode_json_map(""), do: %{}

  def decode_json_map(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value

  def maybe_put_opt(opts, _key, nil), do: opts
  def maybe_put_opt(opts, _key, ""), do: opts
  def maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  def raise_runtime_error!(reason) do
    raise GRPC.RPCError,
      status: runtime_error_status(reason),
      message: MirrorNeuron.Runtime.error_message(reason)
  end

  def backup_error_status(reason) do
    text = inspect(reason)

    cond do
      String.contains?(text, "not found") -> GRPC.Status.not_found()
      String.contains?(text, "must be paused") -> GRPC.Status.failed_precondition()
      true -> GRPC.Status.invalid_argument()
    end
  end

  def valid_admin_token?(configured_token, request_token)
      when is_binary(configured_token) and byte_size(configured_token) > 0 and
             is_binary(request_token) do
    MirrorNeuron.Grpc.Tokens.secure_compare(request_token, configured_token)
  end

  def valid_admin_token?(_configured_token, _request_token), do: false

  defp runtime_error_status({:job_not_running, _job_id}), do: GRPC.Status.not_found()
  defp runtime_error_status({:agent_not_running, _details}), do: GRPC.Status.not_found()

  defp runtime_error_status({:job_call_timeout, _job_id, _timeout_ms}),
    do: GRPC.Status.deadline_exceeded()

  defp runtime_error_status({:job_registry_unavailable, _job_id, _reason}),
    do: GRPC.Status.unavailable()

  defp runtime_error_status({:runtime_lookup_unavailable, _job_id, _reason}),
    do: GRPC.Status.unavailable()

  defp runtime_error_status({:job_call_failed, _job_id, _reason}), do: GRPC.Status.unavailable()

  defp runtime_error_status({:agent_registry_unavailable, _details}),
    do: GRPC.Status.unavailable()

  defp runtime_error_status({:agent_unavailable, _details}), do: GRPC.Status.unavailable()
  defp runtime_error_status({:backpressure, _details}), do: GRPC.Status.resource_exhausted()
  defp runtime_error_status({:retry_later, _details}), do: GRPC.Status.resource_exhausted()

  defp runtime_error_status(reason) do
    message = reason |> MirrorNeuron.Runtime.error_message() |> String.downcase()

    cond do
      String.contains?(message, "not running") -> GRPC.Status.not_found()
      String.contains?(message, "not found") -> GRPC.Status.not_found()
      String.contains?(message, "timed out") -> GRPC.Status.deadline_exceeded()
      String.contains?(message, "timeout") -> GRPC.Status.deadline_exceeded()
      String.contains?(message, "backpressure") -> GRPC.Status.resource_exhausted()
      String.contains?(message, "retry later") -> GRPC.Status.resource_exhausted()
      String.contains?(message, "not paused") -> GRPC.Status.failed_precondition()
      String.contains?(message, "terminal state") -> GRPC.Status.failed_precondition()
      String.contains?(message, "unavailable") -> GRPC.Status.unavailable()
      true -> GRPC.Status.internal()
    end
  end
end
