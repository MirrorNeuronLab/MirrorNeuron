defmodule MirrorNeuron.Runtime.StableJob.StorageTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Runtime.StableJob.Storage

  defp bundle(metadata \\ %{}), do: %{manifest: %{metadata: metadata}, root_path: nil}

  test "explicit storage overrides declarations while preserving unrelated settings" do
    declared = %{
      job_data: %{resources: [%{name: "cache", access: "read"}], retention: "persistent"}
    }

    assert {:ok, storage} =
             Storage.storage_declarations(bundle(declared), %{
               resources: [%{name: "outputs", path: "nested/outputs", access: "read_write"}]
             })

    assert storage["retention"] == "persistent"

    assert storage["resources"] == [
             %{"name" => "outputs", "path" => "nested/outputs", "access" => "read_write"}
           ]
  end

  test "malformed storage containers produce validation errors instead of crashing" do
    for invalid <- [[], [1], "storage", 42, true] do
      assert {:error, :invalid_job_data_declarations} =
               Storage.storage_declarations(bundle(), invalid)

      assert {:error, :invalid_job_data_declarations} =
               Storage.storage_declarations(bundle(%{"job_data" => invalid}), %{})
    end
  end

  test "resource paths and seed types reject values that cannot name safe data" do
    invalid_resources = [
      %{"name" => "../escape"},
      %{"name" => "data", "path" => "/absolute"},
      %{"name" => "bad path"},
      %{"name" => ""},
      %{"name" => "data", "seed" => 1},
      %{"name" => "data", "access" => "execute"},
      nil
    ]

    for resource <- invalid_resources do
      assert {:error, :invalid_job_data_declarations} =
               Storage.storage_declarations(bundle(), %{"resources" => [resource]})
    end
  end

  test "seed directories must exist inside the supplied bundle", %{test: test} do
    root =
      Path.join(
        System.tmp_dir!(),
        "mn-seed-#{:erlang.phash2(test)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "seed"))
    on_exit(fn -> File.rm_rf!(root) end)
    bundle = %{bundle() | root_path: root}
    resource = %{"name" => "data", "path" => "nested/data", "seed" => "@/seed"}

    assert {:ok, %{"nested/data" => source}} =
             Storage.seed_paths(bundle, %{"resources" => [resource]})

    assert source == Path.join(root, "seed")

    for seed <- ["@/../escape", "@/missing"] do
      assert {:error, {:invalid_job_data_seed, "data"}} =
               Storage.seed_paths(bundle, %{"resources" => [Map.put(resource, "seed", seed)]})
    end
  end

  test "shared read access requires every data resource to be read-only" do
    for access <- ["read", "read_only", "ro"] do
      assert Storage.default_job_data_access(%{"resources" => [%{"access" => access}]}) == "read"
    end

    assert Storage.default_job_data_access(%{
             "resources" => [%{"access" => "read"}, %{"access" => "write"}]
           }) == "read_write"

    assert Storage.default_job_data_access(%{"resources" => [%{"name" => "data"}]}) ==
             "read_write"
  end
end
