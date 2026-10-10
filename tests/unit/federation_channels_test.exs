defmodule MirrorNeuron.Cluster.FederationChannelsTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Cluster.{FederationChannels, FederationClient}

  setup do
    parent = self()
    disconnect = fn channel -> send(parent, {:disconnected, channel}) end
    {:ok, disconnect: disconnect}
  end

  test "coalesces concurrent setup and retains the connection owner after callers exit", ctx do
    pool = pool(ctx)
    parent = self()
    channel = %{id: make_ref()}

    connect = fn ->
      send(parent, {:connecting, self()})

      receive do
        :ready -> {:ok, channel}
      end
    end

    tasks =
      for _ <- 1..32, do: Task.async(fn -> FederationChannels.checkout(key(), connect, pool) end)

    assert_receive {:connecting, owner}
    eventually(fn -> map_size(:sys.get_state(pool).leases) == 32 end)
    send(owner, :ready)
    for task <- tasks, do: assert({:ok, _, ^channel} = Task.await(task))
    eventually(fn -> map_size(:sys.get_state(pool).leases) == 0 end)
    assert Process.alive?(owner)
    refute_receive {:connecting, _}, 10
    assert {:ok, lease, ^channel} = FederationChannels.checkout(key(), connect, pool)
    FederationChannels.release(lease, false, pool)
  end

  test "bounds pending callers and frees a pending lease when its caller exits", ctx do
    pool = pool(ctx, max_leases: 2)
    parent = self()

    connect = fn ->
      send(parent, {:connecting, self()})

      receive do
        :ready -> {:ok, :channel}
      end
    end

    first = Task.async(fn -> FederationChannels.checkout(key(), connect, pool) end)
    assert_receive {:connecting, owner}
    second = Task.async(fn -> FederationChannels.checkout(key(), connect, pool) end)
    eventually(fn -> map_size(:sys.get_state(pool).leases) == 2 end)

    assert {:error, :federation_channel_capacity} =
             FederationChannels.checkout(key(), connect, pool)

    Task.shutdown(first, :brutal_kill)
    eventually(fn -> map_size(:sys.get_state(pool).leases) == 1 end)
    send(owner, :ready)
    assert {:ok, _, :channel} = Task.await(second)
    eventually(fn -> map_size(:sys.get_state(pool).leases) == 0 end)
  end

  test "bounds peer entries and evicts only an idle connection", ctx do
    pool = pool(ctx, max_entries: 1)
    assert {:ok, first, :one} = FederationChannels.checkout(key(), fn -> {:ok, :one} end, pool)

    assert {:error, :federation_channel_capacity} =
             FederationChannels.checkout(key("other"), fn -> {:ok, :two} end, pool)

    FederationChannels.release(first, false, pool)

    assert {:ok, second, :two} =
             FederationChannels.checkout(key("other"), fn -> {:ok, :two} end, pool)

    assert_receive {:disconnected, :one}
    FederationChannels.release(second, false, pool)
  end

  test "endpoint, identity and credential changes retire the old channel without interrupting users",
       ctx do
    pool = pool(ctx)
    original = key()

    for replacement <- [
          {"peer", "local", "other:123", "digest"},
          {"peer", "new-local", "peer:123", "digest"},
          {"peer", "local", "peer:123", "new-digest"}
        ] do
      assert {:ok, old, :old} = FederationChannels.checkout(original, fn -> {:ok, :old} end, pool)

      assert {:ok, new, :new} =
               FederationChannels.checkout(replacement, fn -> {:ok, :new} end, pool)

      assert {:error, :federation_channel_draining} =
               FederationChannels.checkout(
                 original,
                 fn -> flunk("reused retired credentials") end,
                 pool
               )

      refute_receive {:disconnected, :old}, 5
      FederationChannels.release(old, false, pool)
      assert_receive {:disconnected, :old}
      FederationChannels.release(new, true, pool)
      assert_receive {:disconnected, :new}
    end
  end

  test "a failed setup replies to all waiters and releases capacity", ctx do
    pool = pool(ctx)
    parent = self()

    connect = fn ->
      send(parent, {:connecting, self()})

      receive do
        :ready -> {:error, :timeout}
      end
    end

    tasks =
      for _ <- 1..2, do: Task.async(fn -> FederationChannels.checkout(key(), connect, pool) end)

    assert_receive {:connecting, owner}
    eventually(fn -> map_size(:sys.get_state(pool).leases) == 2 end)
    send(owner, :ready)
    for task <- tasks, do: assert({:error, :timeout} = Task.await(task))
    assert :sys.get_state(pool).entries == %{}
    assert :sys.get_state(pool).monitors == %{}

    assert {:ok, lease, :recovered} =
             FederationChannels.checkout(key(), fn -> {:ok, :recovered} end, pool)

    FederationChannels.release(lease, false, pool)
  end

  test "connection owner death drains pending callers and allows a later connection", ctx do
    pool = pool(ctx)
    parent = self()

    connect = fn ->
      send(parent, {:connecting, self()})

      receive do
        :ready -> {:ok, :channel}
      end
    end

    task = Task.async(fn -> FederationChannels.checkout(key(), connect, pool) end)
    assert_receive {:connecting, owner}
    Process.exit(owner, :kill)
    assert {:error, :federation_channel_closed} = Task.await(task)
    assert :sys.get_state(pool).entries == %{}

    assert {:ok, lease, :recovered} =
             FederationChannels.checkout(key(), fn -> {:ok, :recovered} end, pool)

    FederationChannels.release(lease, false, pool)
  end

  test "idle sweep preserves active requests and closes idle connections", ctx do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    pool = pool(ctx, clock: fn -> Agent.get(clock, & &1) end, idle_ms: 100)

    assert {:ok, lease, :channel} =
             FederationChannels.checkout(key(), fn -> {:ok, :channel} end, pool)

    Agent.update(clock, fn _ -> 200 end)
    send(pool, :sweep)
    assert map_size(:sys.get_state(pool).entries) == 1
    FederationChannels.release(lease, false, pool)
    assert map_size(:sys.get_state(pool).leases) == 0
    Agent.update(clock, fn _ -> 400 end)
    send(pool, :sweep)
    assert :sys.get_state(pool).entries == %{}
    assert_receive {:disconnected, :channel}
  end

  test "pool shutdown disconnects its retained connections", ctx do
    pool = pool(ctx)

    assert {:ok, _, :channel} =
             FederationChannels.checkout(key(), fn -> {:ok, :channel} end, pool)

    GenServer.stop(pool)
    assert_receive {:disconnected, :channel}
  end

  test "status diagnostics omit credentials in state and last messages", ctx do
    pool = pool(ctx)
    channel = %{headers: [{"authorization", "Bearer test-secret"}]}
    assert {:ok, _, ^channel} = FederationChannels.checkout(key(), fn -> {:ok, channel} end, pool)
    refute inspect(:sys.get_status(pool)) =~ "test-secret"

    safe =
      FederationChannels.format_status(%{
        state: :sys.get_state(pool),
        message: channel,
        reason: channel,
        log: [channel]
      })

    refute inspect(safe) =~ "test-secret"
  end

  test "unary transport failure is never replayed and its channel is retired", ctx do
    pool = pool(ctx)
    parent = self()
    error = GRPC.RPCError.exception(status: GRPC.Status.unavailable(), message: "offline")

    invoke = fn :channel ->
      send(parent, :invoked)
      {:error, error}
    end

    assert {:error, ^error} =
             FederationClient.invoke_unary(key(), fn -> {:ok, :channel} end, invoke, pool)

    assert_receive :invoked
    refute_receive :invoked, 10
    assert_receive {:disconnected, :channel}
    assert :sys.get_state(pool).entries == %{}
  end

  test "unary raised errors release leases while semantic failures retain the connection", ctx do
    pool = pool(ctx)
    not_found = GRPC.RPCError.exception(status: GRPC.Status.not_found(), message: "missing")

    assert_raise GRPC.RPCError, fn ->
      FederationClient.invoke_unary(
        key(),
        fn -> {:ok, :channel} end,
        fn _ -> raise not_found end,
        pool
      )
    end

    assert map_size(:sys.get_state(pool).leases) == 0

    assert {:ok, :result} =
             FederationClient.invoke_unary(
               key(),
               fn -> flunk("unnecessary handshake") end,
               fn _ -> {:ok, :result} end,
               pool
             )

    unavailable = GRPC.RPCError.exception(status: GRPC.Status.unavailable(), message: "offline")

    assert_raise GRPC.RPCError, fn ->
      FederationClient.invoke_unary(
        key(),
        fn -> flunk("unnecessary handshake") end,
        fn _ -> raise unavailable end,
        pool
      )
    end

    assert_receive {:disconnected, :channel}
  end

  test "channel identity includes an irreversible credential digest" do
    peer = %{"peer_auth_token" => "test-secret"}
    actual = FederationClient.channel_key("peer", "peer:123", peer)
    assert elem(actual, 0) == "peer"
    assert elem(actual, 2) == "peer:123"
    assert elem(actual, 3) == :crypto.hash(:sha256, "test-secret")
    refute inspect(actual) =~ "test-secret"

    refute actual ==
             FederationClient.channel_key("peer", "peer:123", %{"peer_auth_token" => "changed"})
  end

  defp pool(ctx, opts \\ []) do
    start_supervised!({FederationChannels, Keyword.put(opts, :disconnect, ctx.disconnect)})
  end

  defp key(peer \\ "peer"), do: {peer, "local", "peer:123", "digest"}

  defp eventually(check, remaining \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, remaining) do
    if not check.() do
      receive do
      after
        1 -> :ok
      end

      eventually(check, remaining - 1)
    end
  end
end
