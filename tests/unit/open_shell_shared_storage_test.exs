defmodule MirrorNeuron.Runner.OpenShellSharedStorageTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runner.OpenShellSharedStorage

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_openshell_shared_storage_#{System.unique_integer([:positive])}"
      )

    shared_root = Path.join(root, "shared")
    job_root = Path.join(shared_root, "submissions/job-1")
    File.mkdir_p!(Path.join(job_root, "inputs"))
    File.mkdir_p!(Path.join(job_root, "outputs"))
    File.write!(Path.join(job_root, "inputs/source.txt"), "source")
    File.write!(Path.join(job_root, "outputs/state.json"), ~s({"value":"before"}))

    previous_shared = System.get_env("MN_SHARED_STORAGE_ROOT")
    previous_temp = System.get_env("MN_TEMP_DIR")
    System.put_env("MN_SHARED_STORAGE_ROOT", shared_root)
    System.put_env("MN_TEMP_DIR", Path.join(root, "tmp"))

    on_exit(fn ->
      restore_env("MN_SHARED_STORAGE_ROOT", previous_shared)
      restore_env("MN_TEMP_DIR", previous_temp)
      File.rm_rf!(root)
    end)

    {:ok, root: root, job_root: job_root}
  end

  test "rewrites, uploads, and durably merges the job-scoped store", %{
    root: root,
    job_root: job_root
  } do
    config = %{
      "sync_shared_storage" => true,
      "sandbox_name" => "sandbox-1",
      "environment" => %{
        "MN_JOB_SHARED_STORAGE_ROOT" => job_root,
        "MN_RUNS_ROOT" => Path.join(job_root, "outputs/runs"),
        "MN_BLUEPRINT_CONFIG_JSON" =>
          Jason.encode!(%{"input_folder" => Path.join(job_root, "inputs")})
      }
    }

    payload = %{"output_folder" => Path.join(job_root, "outputs")}

    assert {:ok, plan} =
             OpenShellSharedStorage.plan(
               payload,
               config,
               "/sandbox/job/agents/researcher",
               attempt: 2,
               invocation: 3
             )

    assert plan.enabled

    assert plan.remote_root ==
             "/sandbox/job/agents/researcher/.mn-shared/i3-a2"

    assert plan.config["environment"]["MN_RUNS_ROOT"] ==
             Path.join(plan.remote_root, "outputs/runs")

    assert plan.payload["output_folder"] ==
             Path.join(plan.remote_root, "outputs")

    {:ok, commands} = Agent.start_link(fn -> [] end)

    runner = fn _executable, args ->
      Agent.update(commands, &[args | &1])

      case args do
        ["sandbox", "download", "sandbox-1", _remote, destination] ->
          File.write!(Path.join(destination, "state.json"), ~s({"value":"after"}))
          {"downloaded", 0}

        _other ->
          {"uploaded", 0}
      end
    end

    assert :ok = OpenShellSharedStorage.upload(plan, "openshell", runner)
    assert :ok = OpenShellSharedStorage.download(plan, "openshell", runner)

    assert File.read!(Path.join(job_root, "outputs/state.json")) ==
             ~s({"value":"after"})

    observed = Agent.get(commands, &Enum.reverse/1)
    assert Enum.count(observed, &Enum.member?(&1, "upload")) == 2
    assert Enum.count(observed, &Enum.member?(&1, "download")) == 1
    assert File.dir?(Path.join(root, "tmp"))
  end

  test "rejects a shared-storage path outside the runtime root", %{
    root: root
  } do
    outside = Path.join(root, "outside")
    File.mkdir_p!(Path.join(outside, "outputs"))

    config = %{
      "sync_shared_storage" => true,
      "environment" => %{"MN_JOB_SHARED_STORAGE_ROOT" => outside}
    }

    assert {:error, message} =
             OpenShellSharedStorage.plan(%{}, config, "/sandbox/job", [])

    assert message =~ "must stay inside the runtime shared root"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
