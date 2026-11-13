defmodule MirrorNeuron.Persistence.RedisStore.ArtifactsTest do
  use MirrorNeuron.RedisStoreCase, async: false

  alias MirrorNeuron.Bundle.Archive
  alias MirrorNeuron.Bundle.Fingerprint
  alias MirrorNeuron.JobBundle
  alias MirrorNeuron.Persistence.RedisStore

  test "register_blob_ref persists shared filesystem locations without urls" do
    sha256 = String.duplicate("d", 64)
    path = Path.join(binary_part(sha256, 0, 2), sha256)

    ref = %{
      "type" => "blob_ref",
      "sha256" => sha256,
      "locations" => [
        %{
          "node" => "node-a@lab",
          "storage" => "shared_fs",
          "root" => "blob_store",
          "path" => path,
          "status" => "available"
        }
      ]
    }

    assert {:ok, blob} = RedisStore.register_blob_ref(ref)
    assert [%{"storage" => "shared_fs", "path" => ^path} = location] = blob["locations"]
    refute Map.has_key?(location, "url")

    assert {:ok, fetched} = RedisStore.fetch_blob_ref(sha256)
    assert [%{"storage" => "shared_fs", "path" => ^path}] = fetched["locations"]
  end

  test "blob listing and retention compact expired metadata indexes", %{namespace: namespace} do
    active_sha = String.duplicate("a", 64)
    listed_stale_sha = String.duplicate("b", 64)
    swept_stale_sha = String.duplicate("c", 64)

    assert {:ok, _blob} =
             RedisStore.register_blob_ref(%{
               "sha256" => active_sha,
               "locations" => [%{"storage" => "shared_fs", "path" => "aa/#{active_sha}"}]
             })

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["blobs"]),
               listed_stale_sha
             ])

    assert {:ok, [%{"sha256" => ^active_sha}]} = RedisStore.list_blob_refs()

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["blobs"]),
               listed_stale_sha
             ])

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SADD",
               redis_key(namespace, ["blobs"]),
               swept_stale_sha
             ])

    assert {:ok, result} = RedisStore.sweep_retention()
    assert result.stale_blob_refs == [swept_stale_sha]
    assert result.stale_blob_ref_count == 1

    assert {:ok, 0} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "SISMEMBER",
               redis_key(namespace, ["blobs"]),
               swept_stale_sha
             ])
  end

  test "retention rebuilds blob metadata still referenced by a persisted job", %{
    namespace: namespace
  } do
    job_id = "blob-retention-job-#{System.unique_integer([:positive])}"
    sha256 = String.duplicate("d", 64)

    ref = %{
      "type" => "blob_ref",
      "sha256" => sha256,
      "payload_path" => "inputs/document.txt",
      "locations" => [%{"storage" => "shared_fs", "path" => "dd/#{sha256}"}]
    }

    assert {:ok, _blob} = RedisStore.register_blob_ref(ref)

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "recovery_status" => "paused_for_review",
               "recovery_requires_review" => true,
               "manifest" => %{"metadata" => %{"blob_refs" => [ref]}},
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:ok, 1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "DEL",
               redis_key(namespace, ["blob", sha256])
             ])

    assert {:error, _reason} = RedisStore.fetch_blob_ref(sha256)
    assert {:ok, _result} = RedisStore.sweep_retention()
    assert {:ok, %{"sha256" => ^sha256}} = RedisStore.fetch_blob_ref(sha256)

    RedisStore.delete_job(job_id)
  end

  test "durable records discover and refresh every referenced bundle archive", %{
    namespace: namespace
  } do
    Application.put_env(:mirror_neuron, :bundle_archive_ttl_seconds, 120)

    job_id = "bundle-ref-job-#{System.unique_integer([:positive])}"
    schedule_id = "bundle-ref-schedule-#{System.unique_integer([:positive])}"
    deployment_key = "bundle-ref-deployment-#{System.unique_integer([:positive])}"
    job_fingerprint = String.duplicate("a", 64)
    schedule_fingerprint = String.duplicate("b", 64)
    version_fingerprint = String.duplicate("c", 64)
    fingerprints = [job_fingerprint, schedule_fingerprint, version_fingerprint]

    on_exit(fn ->
      RedisStore.delete_job(job_id)
      RedisStore.delete_schedule(schedule_id)
    end)

    for fingerprint <- fingerprints do
      assert {:ok, _archive} =
               RedisStore.persist_bundle_archive(fingerprint, %{
                 "graph_id" => "bundle-reference-test",
                 "files" => []
               })
    end

    assert {:ok, _job} =
             RedisStore.persist_job(job_id, %{
               "job_id" => job_id,
               "status" => "running",
               "manifest_ref" => %{"bundle_fingerprint" => job_fingerprint},
               "updated_at" => MirrorNeuron.Runtime.timestamp()
             })

    assert {:ok, _schedule} =
             RedisStore.persist_schedule(schedule_id, %{
               "kind" => "event",
               "status" => "active",
               "enabled" => true,
               "bundle_ref" => %{"bundle_fingerprint" => schedule_fingerprint}
             })

    assert {:ok, _version} =
             RedisStore.persist_job_version(deployment_key, "1", %{
               "manifest_ref" => %{"bundle_fingerprint" => version_fingerprint}
             })

    assert {:ok, ^fingerprints} = RedisStore.referenced_bundle_fingerprints()

    for fingerprint <- fingerprints do
      archive_key = redis_key(namespace, ["bundle", fingerprint])
      assert {:ok, 1} = Redix.command(MirrorNeuron.Redis.Connection, ["EXPIRE", archive_key, "1"])
      assert :ok = RedisStore.refresh_bundle_archive(fingerprint)
      assert {:ok, ttl} = Redix.command(MirrorNeuron.Redis.Connection, ["TTL", archive_key])
      assert ttl == -1
    end

    assert :ok = RedisStore.delete_job(job_id)
    assert :ok = RedisStore.delete_schedule(schedule_id)

    assert {:ok, 2} =
             RedisStore.expire_unreferenced_bundle_archives([version_fingerprint])

    for fingerprint <- [job_fingerprint, schedule_fingerprint] do
      assert {:ok, ttl} =
               Redix.command(MirrorNeuron.Redis.Connection, [
                 "TTL",
                 redis_key(namespace, ["bundle", fingerprint])
               ])

      assert ttl in 100..120
    end

    assert {:ok, -1} =
             Redix.command(MirrorNeuron.Redis.Connection, [
               "TTL",
               redis_key(namespace, ["bundle", version_fingerprint])
             ])
  end

  test "bundle archive store reuses an existing fingerprint archive" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mirror_neuron_archive_cache_#{System.unique_integer([:positive])}"
      )

    cache_dir = Path.join(tmp_dir, "cache")
    old_cache_dir = System.get_env("MN_BUNDLE_CACHE_DIR")
    System.put_env("MN_BUNDLE_CACHE_DIR", cache_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      restore_system_env("MN_BUNDLE_CACHE_DIR", old_cache_dir)
    end)

    bundle_dir = create_bundle(tmp_dir, "cached_archive")
    assert {:ok, fingerprint} = Fingerprint.compute(bundle_dir)

    assert {:ok, _archive} =
             RedisStore.persist_bundle_archive(fingerprint, %{
               "graph_id" => "cached_archive",
               "total_bytes" => 123,
               "files" => archive_files(bundle_dir)
             })

    assert {:ok, bundle} = JobBundle.load(bundle_dir)
    assert {:ok, result} = Archive.store(bundle)

    assert result.storage == "redis"
    assert result.total_bytes == 123
    assert File.exists?(Path.join([cache_dir, fingerprint, "manifest.json"]))
  end
end
