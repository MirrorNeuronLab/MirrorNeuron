defmodule MirrorNeuron.Grpc.RuntimeControlServer do
  @moduledoc """
  Authenticated runtime gateway. Python host work stays in the private native
  service; it uses Core's existing scheduling and ownership commands.
  Channels belong to one request and mutations are never retried.
  """
  use GRPC.Server, service: Mirrorneuron.Runtime.V1.RuntimeControlService.Service

  alias Mirrorneuron.Runtime.V1.RuntimeControlService.Stub

  def execute(%{action: "node.remove"} = request, stream) do
    authorize!(stream)
    validate_version!(request)
    MirrorNeuron.Grpc.RuntimeMembership.remove(request)
  end

  def execute(%{action: "node.detach"} = request, stream) do
    MirrorNeuron.Grpc.Auth.authorize_runtime!(stream, true)
    validate_version!(request)
    MirrorNeuron.Grpc.RuntimeMembership.detach()
  end

  def execute(%{action: action} = request, stream)
      when action in ["mcp.context", "mcp.supervision"] do
    MirrorNeuron.Grpc.Auth.authorize_runtime!(stream, true)
    validate_version!(request)
    {target, request, metadata} = MirrorNeuron.Grpc.RuntimeControlRoute.resolve(request)

    with_channel(target, fn channel ->
      Stub.execute(channel, request, timeout: 120_000, metadata: metadata) |> unwrap!()
    end)
  end

  def execute(request, stream) do
    authorize!(stream)
    validate_version!(request)

    with_channel(fn channel ->
      Stub.execute(channel, request, call_options(:infinity)) |> unwrap!()
    end)
  end

  for method <- [:get_capabilities, :catalog, :prepare, :read] do
    def unquote(method)(request, stream) do
      authorize!(stream)
      validate_version!(request)

      with_channel(fn channel ->
        timeout = if unquote(method) == :prepare, do: :infinity, else: 30_000

        apply(Stub, unquote(method), [channel, request, call_options(timeout)])
        |> unwrap!()
      end)
    end
  end

  for method <- [:events, :read_file] do
    def unquote(method)(request, stream) do
      MirrorNeuron.Grpc.Auth.authorize_runtime!(stream, true)
      validate_version!(request)
      {target, request, metadata} = MirrorNeuron.Grpc.RuntimeControlRoute.resolve(request)

      with_channel(target, fn channel ->
        apply(Stub, unquote(method), [channel, request, [timeout: :infinity, metadata: metadata]])
        |> unwrap!()
        |> send_frames(stream)
      end)
    end
  end

  def upload(frames, stream) do
    authorize!(stream)

    with_channel(fn channel ->
      outgoing = Stub.upload(channel, call_options(:infinity))

      try do
        Enum.each(frames, fn frame ->
          validate_frame!(frame)
          GRPC.Stub.send_request(outgoing, frame)
        end)

        outgoing |> GRPC.Stub.end_stream() |> GRPC.Stub.recv(timeout: :infinity) |> unwrap!()
      after
        GRPC.Stub.cancel(outgoing)
      end
    end)
  end

  def job_ui(frames, stream) do
    MirrorNeuron.Grpc.Auth.authorize_runtime!(stream, true)
    {first, rest} = take_first!(frames)
    validate_frame!(first)
    {target, request, metadata} = MirrorNeuron.Grpc.RuntimeControlRoute.resolve(first.request)
    frames = Stream.concat([%{first | request: request}], rest)

    with_channel(target, fn channel ->
      outgoing = Stub.job_ui(channel, timeout: :infinity, metadata: metadata)

      sender =
        Task.async(fn ->
          Enum.each(frames, fn frame ->
            validate_frame!(frame)
            GRPC.Stub.send_request(outgoing, frame)
          end)

          GRPC.Stub.end_stream(outgoing)
        end)

      try do
        outgoing |> GRPC.Stub.recv(timeout: :infinity) |> unwrap!() |> send_frames(stream)
      after
        Task.shutdown(sender, :brutal_kill)
        GRPC.Stub.cancel(outgoing)
      end
    end)
  end

  defp authorize!(stream), do: MirrorNeuron.Grpc.Auth.authorize_runtime!(stream)

  defp call_options(timeout) do
    [
      timeout: timeout,
      metadata: %{
        "authorization" => "Bearer " <> MirrorNeuron.Grpc.Tokens.runtime_control_token()
      }
    ]
  end

  defp validate_version!(%{version: 1}), do: :ok

  defp validate_version!(_) do
    raise GRPC.RPCError,
      status: GRPC.Status.failed_precondition(),
      message: "Unsupported runtime control version"
  end

  defp validate_frame!(frame) do
    validate_version!(frame)

    if byte_size(frame.data) > 65_536 do
      raise GRPC.RPCError,
        status: GRPC.Status.resource_exhausted(),
        message: "Runtime stream frame is too large"
    end
  end

  defp send_frames(frames, stream) do
    Enum.each(frames, fn result ->
      frame = unwrap!(result)
      validate_frame!(frame)
      GRPC.Server.send_reply(stream, frame)
    end)
  end

  defp with_channel(callback) do
    target = System.get_env("MN_NATIVE_SDK_GRPC_TARGET", "") |> String.trim()

    if target == "" do
      raise GRPC.RPCError,
        status: GRPC.Status.unavailable(),
        message: "The native runtime service is not configured"
    end

    with_channel(target, callback)
  end

  defp with_channel(target, callback) do
    channel = GRPC.Stub.connect(target, timeout: 5_000) |> unwrap!()

    try do
      callback.(channel)
    after
      GRPC.Stub.disconnect(channel)
    end
  end

  defp take_first!(frames) do
    case Enumerable.reduce(frames, {:cont, nil}, fn frame, _ -> {:suspend, frame} end) do
      {:suspended, %{kind: "request", request: request} = first, continuation}
      when not is_nil(request) ->
        rest =
          Stream.resource(
            fn -> continuation end,
            fn
              nil ->
                {:halt, nil}

              next ->
                case next.({:cont, nil}) do
                  {:suspended, item, following} -> {[item], following}
                  {:done, _} -> {:halt, nil}
                  {:halted, _} -> {:halt, nil}
                end
            end,
            fn
              nil -> :ok
              next -> next.({:halt, nil})
            end
          )

        {first, rest}

      _ ->
        raise GRPC.RPCError,
          status: GRPC.Status.invalid_argument(),
          message: "Job UI metadata must be the first frame"
    end
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, %GRPC.RPCError{} = error}), do: raise(error)

  defp unwrap!({:error, _}) do
    raise GRPC.RPCError,
      status: GRPC.Status.unavailable(),
      message: "The native runtime service is unavailable"
  end
end
