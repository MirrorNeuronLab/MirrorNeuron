defmodule MirrorNeuron.Artifacts.SyncthingPublicationTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Artifacts.SyncthingPublication

  setup do
    names =
      ~w(MN_SYNCTHING_ENABLED MN_SYNCTHING_API_KEY MN_SYNCTHING_ADVERTISE_HOST MN_SYNCTHING_GUI_PORT MN_SYNCTHING_FOLDER_ID MN_SHARED_STORAGE_ROOT MN_RUNTIME_SHARED_STORAGE_ROOT)

    saved = Map.new(names, &{&1, System.get_env(&1)})
    System.put_env("MN_SYNCTHING_ENABLED", "auto")
    System.put_env("MN_SYNCTHING_API_KEY", "test-publication-key")
    System.put_env("MN_SYNCTHING_ADVERTISE_HOST", "127.0.0.1")
    System.put_env("MN_SYNCTHING_FOLDER_ID", "test-shared")

    on_exit(fn ->
      Enum.each(saved, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
    end)

    :ok
  end

  test "publishes only the selected submission output subtree" do
    root = Path.join(System.tmp_dir!(), "mn-publication-#{System.unique_integer([:positive])}")
    submission = Path.join([root, "submissions", "owned"])
    run = Path.join([submission, "outputs", "runs", "actual-run"])
    File.mkdir_p!(run)
    File.write!(Path.join(run, "report.txt"), "committed test result")
    System.put_env("MN_SHARED_STORAGE_ROOT", root)
    System.delete_env("MN_RUNTIME_SHARED_STORAGE_ROOT")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    System.put_env("MN_SYNCTHING_GUI_PORT", to_string(port))
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)

        assert %{"status" => "completed"} =
                 Jason.decode!(File.read!(Path.join(run, ".mn_completion.json")))

        send(parent, {:scan_request, request})
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        :gen_tcp.close(socket)
      end)

    assert :ok =
             MirrorNeuron.Artifacts.SharedStorage.publish_run_completion(
               %{
                 "metadata" => %{
                   "mn_storage" => %{
                     "submission_path" => submission,
                     "output_copy_executor" => "master_host"
                   }
                 }
               },
               "actual-run",
               "completed"
             )

    assert_receive {:scan_request, request}
    assert request =~ "POST /rest/db/scan?"
    assert request =~ "folder=test-shared"
    assert request =~ "sub=submissions%2Fowned%2Foutputs"
    assert String.downcase(request) =~ "x-api-key: test-publication-key"
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "disabled or unconfigured sidecars do not contact a service" do
    System.put_env("MN_SYNCTHING_ENABLED", "0")
    assert :ok = SyncthingPublication.publish("/root", "/root/submissions/owned/outputs")
    System.put_env("MN_SYNCTHING_ENABLED", "auto")
    System.delete_env("MN_SYNCTHING_API_KEY")
    assert :ok = SyncthingPublication.publish("/root", "/root/submissions/owned/outputs")
  end

  test "rejects paths outside shared storage and the shared root itself" do
    assert {:error, :invalid_publication_path} =
             SyncthingPublication.publish("/root", "/other/outputs")

    assert {:error, :invalid_publication_path} = SyncthingPublication.publish("/root", "/root")
  end
end
