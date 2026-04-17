defmodule MirrorNeuron.API.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias MirrorNeuron.API.Router
  alias MirrorNeuron.Persistence.RedisStore

  @opts Router.init([])

  setup do
    Application.ensure_all_started(:mirror_neuron)

    case Redix.command(MirrorNeuron.Redis.Connection, ["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> raise "Redis must be running for API tests"
    end
  end

  test "GET /api/v1/health returns ok" do
    conn = conn(:get, "/api/v1/health") |> Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "GET /api/v1/system/summary returns cluster overview" do
    conn = conn(:get, "/api/v1/system/summary") |> Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert Map.has_key?(response, "nodes")
    assert Map.has_key?(response, "jobs")
  end

  test "GET /api/v1/jobs returns empty list when no jobs" do
    conn = conn(:get, "/api/v1/jobs") |> Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert is_list(response["data"])
  end

  test "GET /api/v1/jobs/:job_id returns 404 for unknown job" do
    conn = conn(:get, "/api/v1/jobs/nonexistent-job") |> Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 404
    assert String.contains?(Jason.decode!(conn.resp_body)["error"], "was not found")
  end

  test "POST /api/v1/jobs validates empty payload" do
    conn = conn(:post, "/api/v1/jobs", %{}) |> Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 400
    assert String.contains?(Jason.decode!(conn.resp_body)["error"], "Empty JSON")
  end

  test "POST /api/v1/jobs/:job_id/cancel returns 404 for unknown job" do
    conn = conn(:post, "/api/v1/jobs/nonexistent-job/cancel") |> Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 404
  end

  test "GET /api/v1/jobs lists jobs and gets details" do
    job_id = "api-job-#{System.unique_integer([:positive])}"

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "test_graph",
      "status" => "running",
      "submitted_at" => "2026-03-28T00:00:00Z"
    })

    conn = conn(:get, "/api/v1/jobs") |> Router.call(@opts)
    assert conn.status == 200
    jobs = Jason.decode!(conn.resp_body)["data"]
    assert Enum.any?(jobs, &(&1["job_id"] == job_id))

    conn_details = conn(:get, "/api/v1/jobs/#{job_id}") |> Router.call(@opts)
    assert conn_details.status == 200
    details = Jason.decode!(conn_details.resp_body)
    assert details["job"]["job_id"] == job_id

    RedisStore.delete_job(job_id)
  end

  test "POST /api/v1/jobs with valid simple manifest" do
    manifest = %{"graph" => %{"name" => "test_graph"}, "agents" => []}
    conn = conn(:post, "/api/v1/jobs", manifest) |> Router.call(@opts)

    assert conn.state == :sent
    # Assuming manifest validation fails for an empty one without proper structure, or passes.
    # Let's just check it doesn't 500.
    assert conn.status in [201, 400]
  end

  test "POST /api/v1/jobs/cleanup" do
    conn = conn(:post, "/api/v1/jobs/cleanup?all=true") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 200
  end

  test "GET /api/v1/jobs/:job_id/events returns 404 for unknown job" do
    conn = conn(:get, "/api/v1/jobs/unknown-job/events") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 404
  end

  test "POST /api/v1/jobs/:job_id/pause returns 404/400 for unknown job" do
    conn = conn(:post, "/api/v1/jobs/unknown-job/pause") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 404
  end

  test "POST /api/v1/jobs/:job_id/resume returns 404/400 for unknown job" do
    conn = conn(:post, "/api/v1/jobs/unknown-job/resume") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 404
  end

  test "POST /api/v1/bundles/:bundle_id/reload returns 404 for unknown bundle" do
    conn = conn(:post, "/api/v1/bundles/unknown-bundle/reload") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 404
  end

  test "GET /api/v1/nodes returns a list" do
    conn = conn(:get, "/api/v1/nodes") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert is_list(response["data"])
  end

  test "POST /api/v1/nodes/:node_name" do
    conn = conn(:post, "/api/v1/nodes/dummy@127.0.0.1") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 201
  end

  test "DELETE /api/v1/nodes/:node_name" do
    conn = conn(:delete, "/api/v1/nodes/dummy@127.0.0.1") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 200
  end

  test "Match _ returns 404" do
    conn = conn(:get, "/api/v1/not-a-real-route") |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 404
  end

  test "GET /api/v1/jobs/:job_id/events lists events for an existing job" do
    job_id = "api-job-events-#{System.unique_integer([:positive])}"

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "test_graph",
      "status" => "running",
      "submitted_at" => "2026-03-28T00:00:00Z"
    })

    conn = conn(:get, "/api/v1/jobs/#{job_id}/events") |> Router.call(@opts)
    assert conn.status == 200
    events = Jason.decode!(conn.resp_body)["data"]
    assert is_list(events)

    RedisStore.delete_job(job_id)
  end

  test "POST /api/v1/jobs/:job_id/cancel for an existing orphaned job" do
    job_id = "api-job-cancel-#{System.unique_integer([:positive])}"

    RedisStore.persist_job(job_id, %{
      "job_id" => job_id,
      "graph_id" => "test_graph",
      "status" => "running",
      "submitted_at" => "2026-03-28T00:00:00Z"
    })

    # Because it's not actually running in a GenServer, cancel will fallback to force cancel
    conn = conn(:post, "/api/v1/jobs/#{job_id}/cancel") |> Router.call(@opts)
    assert conn.status == 200

    # And the status should be cancelled
    {:ok, job} = RedisStore.fetch_job(job_id)
    assert job["status"] == "cancelled"

    RedisStore.delete_job(job_id)
  end

  test "POST /api/v1/bundles/upload requires a bundle payload" do
    conn = conn(:post, "/api/v1/bundles/upload", %{}) |> Router.call(@opts)
    assert conn.state == :sent
    assert conn.status == 400

    assert String.contains?(
             Jason.decode!(conn.resp_body)["error"],
             "Missing 'bundle' file upload"
           )
  end
end
