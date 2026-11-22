defmodule MirrorNeuron.Grpc.SharedResponse do
  @moduledoc """
  Negotiated file-backed replies. The reference carries the key in the RPC;
  Syncthing replicates only authenticated ciphertext under a digest-derived name.
  """
  @behaviour GRPC.Server.Interceptor
  alias MirrorNeuron.Artifacts.SharedStorage
  alias MirrorNeuron.Grpc.SharedResponse.{ClientCodec, ServerCodec}

  @header "x-mn-shared-response"
  @magic <<0, "MNGR", 1>>
  @inline 4 * 1024 * 1024
  @file_prefix "grpc-response-v1-"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(request, %{codec: GRPC.Codec.Proto} = stream, next, _opts) do
    if GRPC.Stream.get_headers(stream)[@header] == "v1" and File.dir?(SharedStorage.root()) do
      # The gRPC server uses the returned stream for unary replies. Streaming
      # handlers send each frame through the stream passed to the handler.
      case next.(request, %{stream | codec: ServerCodec}) do
        {:ok, original, reply} -> {:ok, %{original | codec: ServerCodec}, reply}
        other -> other
      end
    else
      next.(request, stream)
    end
  end

  def call(request, stream, next, _opts), do: next.(request, stream)

  def client_options(opts) do
    if File.dir?(SharedStorage.root()) do
      opts
      |> Keyword.put(:codec, ClientCodec)
      |> Keyword.update(:headers, [{@header, "v1"}], &[{@header, "v1"} | &1])
    else
      opts
    end
  end

  def encode(data, type, root) when byte_size(data) > @inline do
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, data, type, true)
    blob = [nonce, ciphertext, tag]
    digest = :crypto.hash(:sha256, blob)

    temp =
      Path.join(
        root,
        ".syncthing.mn-grpc-" <> Base.encode16(:crypto.strong_rand_bytes(16)) <> ".tmp"
      )

    # A complete, atomic rename is visible to local readers and the sync watcher.
    File.open!(temp, [:write, :binary, :exclusive], fn io ->
      try do
        :ok = IO.binwrite(io, blob)
        :ok = :file.sync(io)
        File.chmod!(temp, 0o644)
        File.rename!(temp, path(root, digest))
      after
        File.rm(temp)
      end
    end)

    sweep(root)
    <<@magic, byte_size(data)::64, digest::binary, key::binary>>
  end

  def encode(data, _type, _root), do: data

  def decode(<<@magic, size::64, digest::binary-size(32), key::binary-size(32)>>, type, root)
      when size > @inline and size <= 2_147_483_647 do
    file = path(root, digest)
    wait_for_replica(file, size + 28, System.monotonic_time(:millisecond) + 60_000)

    with {:ok, bytes} <- File.open(file, [:read, :binary], &IO.binread(&1, size + 29)),
         <<nonce::binary-size(12), encrypted::binary-size(^size), tag::binary-size(16)>> <- bytes,
         ^digest <- :crypto.hash(:sha256, bytes),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, encrypted, type, tag, false) do
      plain
    else
      _ ->
        raise GRPC.RPCError,
          status: :data_loss,
          message: "Shared gRPC response integrity check failed"
    end
  end

  def decode(<<@magic, _::binary>>, _type, _root),
    do:
      raise(GRPC.RPCError, status: :data_loss, message: "Invalid shared gRPC response reference")

  def decode(data, _type, _root), do: data

  defp wait_for_replica(file, size, deadline) do
    case File.lstat(file) do
      {:ok, %{type: :regular, size: ^size}} ->
        :ok

      {:error, :enoent} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          raise GRPC.RPCError,
            status: :deadline_exceeded,
            message: "Shared gRPC response did not arrive on this Syncthing replica"
        end

        Process.sleep(min(150, remaining))
        wait_for_replica(file, size, deadline)

      _ ->
        raise GRPC.RPCError, status: :data_loss, message: "Invalid shared gRPC response file"
    end
  end

  defp path(root, digest),
    do: Path.join(root, @file_prefix <> Base.encode16(digest, case: :lower) <> ".bin")

  defp sweep(root) do
    now = System.system_time(:second)
    stamp = {__MODULE__, root}

    if now - :persistent_term.get(stamp, 0) >= 3600 do
      :persistent_term.put(stamp, now)

      for name <- Path.wildcard(Path.join(root, @file_prefix <> "*.bin")),
          Regex.match?(~r/^grpc-response-v1-[0-9a-f]{64}\.bin$/, Path.basename(name)),
          {:ok, %{type: :regular, mtime: mtime}} <- [File.lstat(name, time: :posix)],
          mtime < now - 86400 do
        File.rm(name)
      end
    end
  end
end

defmodule MirrorNeuron.Grpc.SharedResponse.ServerCodec do
  @moduledoc false
  @behaviour GRPC.Codec
  defdelegate name(), to: GRPC.Codec.Proto
  defdelegate decode(data, module), to: GRPC.Codec.Proto

  def encode(%module{} = message) do
    MirrorNeuron.Grpc.SharedResponse.encode(
      module.encode(message),
      module.full_name(),
      MirrorNeuron.Artifacts.SharedStorage.root()
    )
  end
end

defmodule MirrorNeuron.Grpc.SharedResponse.ClientCodec do
  @moduledoc false
  @behaviour GRPC.Codec
  defdelegate name(), to: GRPC.Codec.Proto
  defdelegate encode(message), to: GRPC.Codec.Proto

  def decode(data, module) do
    data
    |> MirrorNeuron.Grpc.SharedResponse.decode(
      module.full_name(),
      MirrorNeuron.Artifacts.SharedStorage.root()
    )
    |> module.decode()
  end
end
