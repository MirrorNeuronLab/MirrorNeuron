defmodule MirrorNeuron.Grpc.JobProjectionTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Grpc.JobProjection

  test "job responses reference archived bundles without echoing manifests" do
    definition = %{
      "job_id" => "job-1",
      "graph_id" => "large-workflow",
      "job_name" => "Large workflow",
      "status" => "active",
      "data_generation" => 1,
      "manifest" => %{"flow" => String.duplicate("x", 4_500_000)},
      "data_dir" => "/private/job-data/job-1",
      "resolved_configuration" => %{"mode" => "safe"},
      "run_ids" => ["run-1", "run-2"],
      "schedule_ids" => ["schedule-1"],
      "bundle_ref" => %{
        "bundle_fingerprint" => String.duplicate("a", 64),
        "bundle_storage" => "shared",
        "bundle_bytes" => 5_000_000,
        "cache_path" => "/private/shared/bundles/fingerprint",
        "job_path" => "/private/request/bundle",
        "manifest_path" => "/private/request/bundle/manifest.json"
      }
    }

    summary = JobProjection.summary(definition)
    detail = JobProjection.detail(definition)

    for projected <- [summary, detail] do
      refute Map.has_key?(projected, "manifest")
      refute Map.has_key?(projected, "data_dir")
      refute Map.has_key?(projected, "run_ids")
      refute Map.has_key?(projected["bundle_ref"], "cache_path")
      refute Map.has_key?(projected["bundle_ref"], "job_path")
      refute Map.has_key?(projected["bundle_ref"], "manifest_path")
      assert projected["run_count"] == 2
      assert projected["schedule_count"] == 1
      assert byte_size(Jason.encode!(projected)) < 10_000
    end

    assert detail["resolved_configuration"] == %{"mode" => "safe"}
    assert detail["recent_run_ids"] == ["run-2", "run-1"]
    refute Map.has_key?(summary, "resolved_configuration")
  end

  test "run and schedule responses omit their archived manifests and histories" do
    large_manifest = %{"flow" => String.duplicate("x", 4_500_000)}

    run =
      JobProjection.run(%{
        "job_id" => "run-1",
        "stable_job_id" => "job-1",
        "status" => "running",
        "attempt" => 2,
        "manifest" => large_manifest,
        "workflow_state" => %{"output" => String.duplicate("y", 1_000_000)},
        "manifest_ref" => %{
          "bundle_fingerprint" => String.duplicate("b", 64),
          "cache_path" => "/private/cache"
        }
      })

    schedule =
      JobProjection.schedule(%{
        "schedule_id" => "schedule-1",
        "job_id" => "job-1",
        "status" => "active",
        "manifest" => large_manifest,
        "dispatches" => [%{"run_id" => "run-1"}],
        "active_run_ids" => ["run-1"],
        "bundle_ref" => %{
          "bundle_fingerprint" => String.duplicate("c", 64),
          "job_path" => "/private/request"
        }
      })

    assert run["job_id"] == "job-1"
    assert run["run_id"] == "run-1"
    assert run["attempt_id"] == "run-1:2"
    refute Map.has_key?(run, "manifest")
    refute Map.has_key?(run, "workflow_state")
    refute Map.has_key?(run["manifest_ref"], "cache_path")

    assert schedule["dispatch_count"] == 1
    assert schedule["active_run_count"] == 1
    refute Map.has_key?(schedule, "manifest")
    refute Map.has_key?(schedule, "dispatches")
    refute Map.has_key?(schedule["bundle_ref"], "job_path")

    assert byte_size(Jason.encode!(run)) < 10_000
    assert byte_size(Jason.encode!(schedule)) < 10_000
  end

  test "job projections expose only sanitized response service lifecycle state" do
    definition = %{
      "job_id" => "job-response-1",
      "status" => "active",
      "manifest" => %{"response_service" => %{"enabled" => true}},
      "response_service" => %{
        "state" => "ready",
        "ready_at" => "2026-08-20T10:00:00Z",
        "endpoint" => "http://127.0.0.1:9999/private",
        "token" => "secret",
        "safe_error_code" => nil
      }
    }

    projected = JobProjection.detail(definition)

    assert projected["response_service"]["state"] in ~w(starting ready)
    refute Map.has_key?(projected["response_service"], "endpoint")
    refute Map.has_key?(projected["response_service"], "token")

    disabled = JobProjection.detail(%{"job_id" => "job-disabled"})
    assert disabled["response_service"] == %{"state" => "disabled"}
  end

  test "job response workers ignore transient transport messages" do
    assert {:noreply, %{}} =
             MirrorNeuron.Runtime.JobResponse.handle_info(
               {:gun_down, self(), make_ref(), :closed, []},
               %{}
             )
  end
end
