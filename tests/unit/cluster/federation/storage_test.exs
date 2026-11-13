defmodule MirrorNeuron.Cluster.FederationRegistry.StorageTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Cluster.FederationRegistry.Storage

  setup do
    previous = System.get_env("MN_HOME")

    home =
      Path.join(System.tmp_dir!(), "mn-federation-storage-#{System.unique_integer([:positive])}")

    System.put_env("MN_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("MN_HOME", previous), else: System.delete_env("MN_HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "concurrent updates serialize their read-modify-write cycle" do
    parent = self()

    first =
      Task.async(fn ->
        Storage.update_registry(fn peers ->
          send(parent, :first_entered)

          receive do
            :release -> :ok
          after
            2000 -> raise "lock test release timed out"
          end

          {:ok, Map.put(peers, "first", %{}), nil, "saved"}
        end)
      end)

    assert_receive :first_entered

    second =
      Task.async(fn ->
        send(parent, :second_started)

        Storage.update_registry(fn peers ->
          send(parent, :second_entered)
          {:ok, Map.put(peers, "second", %{}), nil, "saved"}
        end)
      end)

    try do
      assert_receive :second_started
      refute_receive :second_entered, 100
    after
      send(first.pid, :release)
      Task.await(first)
      Task.await(second)
    end

    assert Map.keys(Storage.read_registry()) |> Enum.sort() == ["first", "second"]
  end

  test "failed updates leave the committed private registry unchanged", %{home: home} do
    peer = %{"peer_auth_token" => "scoped", "job_projections" => %{"large" => true}}

    assert {:ok, nil, "saved"} =
             Storage.update_registry(fn _ -> {:ok, %{"peer" => peer}, nil, "saved"} end)

    assert {:error, :conflict} = Storage.update_registry(fn _ -> {:error, :conflict} end)
    assert %{"peer" => %{"peer_auth_token" => "scoped"}} = Storage.read_registry()
    refute Map.has_key?(Storage.read_registry()["peer"], "job_projections")

    assert Bitwise.band(File.stat!(Path.join([home, "federation", "peers.json"])).mode, 0o777) ==
             0o600
  end
end
