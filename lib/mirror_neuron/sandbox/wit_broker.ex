defmodule MirrorNeuron.Sandbox.WitBroker do
  @moduledoc "Private framed channel between the native Wasmtime linker and the current invocation."
  @budget 16 * 1024 * 1024
  @grants ~w(artifacts.import-block artifacts.read artifacts.verify artifacts.commit artifacts.commit-json artifacts.static-report artifacts.publish approvals.request approvals.status model.generate-json mailbox.send mailbox.list mailbox.attachment mailbox.acknowledge)
  @skill_grant ~r/\Askill\.[a-z]+(?:-[a-z]+)*\.[a-z]+(?:-[a-z]+)*\z/

  def validate(grants) when is_list(grants) do
    if Enum.all?(grants, &valid_grant?/1) and Enum.uniq(grants) == grants,
      do: :ok,
      else: {:error, "Invalid WIT host capability grants"}
  end

  def validate(_), do: {:error, "WIT host capabilities must be a list"}

  defp valid_grant?(grant) when is_binary(grant) and byte_size(grant) <= 134,
    do: grant in @grants or Regex.match?(@skill_grant, grant)

  defp valid_grant?(_), do: false

  def with_socket(grants, dispatch, callback) do
    # A system temporary directory also keeps the sockaddr below sun_path's limit.
    dir =
      Path.join(
        System.tmp_dir!(),
        "mn-wit-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      )

    socket = Path.join(dir, "run.sock")

    with :ok <- File.mkdir(dir) do
      try do
        with :ok <- File.chmod(dir, 0o700),
             {:ok, listener} <-
               :gen_tcp.listen(0, [
                 :binary,
                 active: false,
                 ifaddr: {:local, to_charlist(socket)},
                 packet: 4,
                 packet_size: @budget
               ]) do
          server =
            Task.async(fn ->
              with {:ok, peer} <- :gen_tcp.accept(listener) do
                try do
                  serve(peer, grants, dispatch)
                after
                  :gen_tcp.close(peer)
                end
              end
            end)

          try do
            callback.(socket)
          after
            :gen_tcp.close(listener)
            Task.shutdown(server, :brutal_kill)
          end
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  defp serve(peer, grants, dispatch) do
    with {:ok, packet} <- :gen_tcp.recv(peer, 0) do
      response =
        case Jason.decode(packet) do
          {:ok, %{"service" => service, "operation" => op, "args" => args}}
          when is_binary(service) and is_binary(op) and is_list(args) ->
            key = service <> "." <> op

            if key in grants,
              do: reply(fn -> dispatch.(key, args) end),
              else: %{"error" => "Capability denied"}

          _ ->
            %{"error" => "Invalid service request"}
        end

      data = Jason.encode!(response)

      bounded =
        if byte_size(data) <= @budget,
          do: data,
          else: ~s({"error":"Service response exceeds its byte limit"})

      with :ok <- :gen_tcp.send(peer, bounded), do: serve(peer, grants, dispatch)
    end
  end

  defp reply(fun) do
    case fun.() do
      {:ok, content} when is_binary(content) -> %{"ok" => content}
      {:ok, value} -> %{"ok" => Jason.encode!(value)}
      {:error, reason} when is_atom(reason) -> %{"error" => Atom.to_string(reason)}
      _ -> %{"error" => "Run service request failed"}
    end
  rescue
    _ -> %{"error" => "Run service request failed"}
  catch
    :exit, _ -> %{"error" => "Run service unavailable"}
  end
end
