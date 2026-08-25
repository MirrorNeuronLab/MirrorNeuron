defmodule MirrorNeuron.JobDataTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.JobData

  setup do
    root = Path.join(System.tmp_dir!(), "mn-job-data-#{System.unique_integer([:positive])}")
    previous = System.get_env("MN_JOB_DATA_ROOT")
    System.put_env("MN_JOB_DATA_ROOT", root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous do
        System.put_env("MN_JOB_DATA_ROOT", previous)
      else
        System.delete_env("MN_JOB_DATA_ROOT")
      end
    end)

    {:ok, root: root}
  end

  test "derives direct-child paths and rejects traversal", %{root: root} do
    assert {:ok, path} = JobData.path("job_alpha-1")
    assert path == Path.join(root, "job_alpha-1")
    assert {:error, :invalid_job_id} = JobData.path("../outside")
    assert {:error, :invalid_job_id} = JobData.path("nested/job")
  end

  test "seeds only once and reset creates a clean generation directory" do
    seed = Path.join(System.tmp_dir!(), "mn-job-seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(seed)
    File.write!(Path.join(seed, "knowledge.txt"), "v1")

    on_exit(fn -> File.rm_rf(seed) end)

    assert {:ok, path} = JobData.initialize("job_seed", %{"knowledge" => seed})
    copied = Path.join([path, "knowledge", "knowledge.txt"])
    assert File.read!(copied) == "v1"

    File.write!(copied, "user edit")
    assert {:ok, ^path} = JobData.initialize("job_seed", %{"knowledge" => seed})
    assert File.read!(copied) == "user edit"

    assert {:ok, ^path} = JobData.reset("job_seed")
    refute File.exists?(copied)
  end

  test "job and seeded resource roots inherit the bind mount owner", %{root: root} do
    seed = Path.join(System.tmp_dir!(), "mn-job-owner-seed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(seed)
    File.write!(Path.join(seed, "knowledge.txt"), "seed")

    on_exit(fn -> File.rm_rf(seed) end)

    assert {:ok, path} = JobData.initialize("job_owner", %{"knowledge" => seed})
    assert {:ok, owner} = File.stat(Path.dirname(root))
    assert {:ok, job} = File.stat(path)
    assert {:ok, resource} = File.stat(Path.join(path, "knowledge"))

    assert {job.uid, job.gid} == {owner.uid, owner.gid}
    assert {resource.uid, resource.gid} == {owner.uid, owner.gid}
  end

  test "refuses a symlink job directory", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "mn-job-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.mkdir_p!(root)
    File.ln_s!(outside, Path.join(root, "job_link"))

    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, :job_data_symlink_not_allowed} = JobData.initialize("job_link")
    assert {:error, :job_data_symlink_not_allowed} = JobData.delete("job_link")
  end

  test "refuses a symlink job-data root", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "mn-job-root-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.ln_s!(outside, root)

    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, :job_data_symlink_not_allowed} = JobData.initialize("job_root_link")
    assert {:error, :job_data_symlink_not_allowed} = JobData.reset("job_root_link")
    assert {:error, :job_data_symlink_not_allowed} = JobData.delete("job_root_link")
  end

  test "refuses symlink escapes introduced inside existing job data" do
    assert {:ok, path} = JobData.initialize("job_inner_link")

    outside =
      Path.join(System.tmp_dir!(), "mn-job-inner-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(path, "escaped"))

    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, :job_data_symlink_not_allowed} = JobData.initialize("job_inner_link")
  end

  test "supports nested declared resource paths and rejects symlink seeds" do
    seed = Path.join(System.tmp_dir!(), "mn-job-seed-#{System.unique_integer([:positive])}")

    outside =
      Path.join(System.tmp_dir!(), "mn-job-seed-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(seed)
    File.mkdir_p!(outside)
    File.write!(Path.join(seed, "rag.db"), "seed")

    on_exit(fn ->
      File.rm_rf(seed)
      File.rm_rf(outside)
    end)

    assert {:ok, path} = JobData.initialize("job_nested", %{"databases/rag" => seed})
    assert File.read!(Path.join([path, "databases", "rag", "rag.db"])) == "seed"

    linked =
      Path.join(System.tmp_dir!(), "mn-job-linked-seed-#{System.unique_integer([:positive])}")

    File.ln_s!(outside, linked)
    on_exit(fn -> File.rm_rf(linked) end)

    assert {:error, :seed_symlink_not_allowed} =
             JobData.initialize("job_linked_seed", %{"knowledge" => linked})
  end
end
