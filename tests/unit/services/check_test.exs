defmodule MirrorNeuron.ServiceCheckTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.ServiceCheck

  defmodule HealthServer do
    use GRPC.Server, service: Grpc.Health.V1.Health.Service

    def check(_request, _stream) do
      %Grpc.Health.V1.HealthCheckResponse{status: :SERVING}
    end
  end

  defmodule HealthEndpoint do
    use GRPC.Endpoint

    run(HealthServer)
  end

  test "http checks pass and redact sensitive query values" do
    port =
      start_http_server("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")

    report =
      ServiceCheck.check_service(%{
        "id" => "svc-http",
        "name" => "ollama",
        "checks" => [
          %{
            "name" => "ready",
            "type" => "http",
            "url" => "http://127.0.0.1:#{port}/health?api_key=secret",
            "contains" => "ok",
            "timeout_ms" => 1_000
          }
        ]
      })

    assert report["status"] == "passing"
    assert get_in(report, ["checks", Access.at(0), "status"]) == "passing"
    refute inspect(report) =~ "secret"
  end

  test "tcp checks pass against reachable ports" do
    port = start_tcp_server()

    report =
      ServiceCheck.check_service(%{
        "id" => "svc-tcp",
        "name" => "vector-db",
        "address" => "127.0.0.1",
        "port" => port,
        "checks" => [%{"name" => "socket", "type" => "tcp", "timeout_ms" => 1_000}]
      })

    assert report["status"] == "passing"
  end

  test "script checks are reported as SDK-owned preparation" do
    root = Path.join(System.tmp_dir!(), "mn-service-check-#{System.unique_integer([:positive])}")
    Process.put(:service_check_root, root)
    File.mkdir_p!(root)
    script = Path.join(root, "ok.sh")
    File.write!(script, "#!/bin/sh\n[ \"$MN_SERVICE_NAME\" = agent-api ]\n")
    File.chmod!(script, 0o755)

    report =
      ServiceCheck.check_service(
        %{
          "id" => "svc-script",
          "name" => "agent-api",
          "checks" => [%{"name" => "script", "type" => "script", "command" => ["./ok.sh"]}]
        },
        bundle_root: root
      )

    assert report["status"] == "critical"

    assert get_in(report, ["checks", Access.at(0), "error"]) =~
             "script service checks are owned by mn-python-sdk"
  after
    if root = Process.delete(:service_check_root), do: File.rm_rf(root)
  end

  test "optional check failures downgrade service health to warning" do
    report =
      ServiceCheck.check_service(%{
        "id" => "svc-optional",
        "name" => "optional-api",
        "address" => "127.0.0.1",
        "port" => 9,
        "checks" => [
          %{"name" => "optional", "type" => "tcp", "required" => false, "timeout_ms" => 50}
        ]
      })

    assert report["status"] == "warning"
    assert get_in(report, ["checks", Access.at(0), "status"]) == "critical"
  end

  test "failure thresholds suppress transient required check failures" do
    service = %{
      "id" => "svc-threshold",
      "name" => "dashboard",
      "checks" => [
        %{
          "name" => "ready",
          "type" => "http",
          "required" => true,
          "failures_before_critical" => 3
        }
      ]
    }

    health = %{
      "status" => "critical",
      "checks" => [
        %{"name" => "ready", "type" => "http", "required" => true, "status" => "critical"}
      ]
    }

    {first_health, first_counts} = ServiceCheck.apply_failure_thresholds(service, health)

    assert first_health["status"] == "passing"
    assert get_in(first_health, ["checks", Access.at(0), "status"]) == "passing"
    assert get_in(first_health, ["checks", Access.at(0), "suppressed_status"]) == "critical"
    assert get_in(first_health, ["checks", Access.at(0), "consecutive_failures"]) == 1

    {second_health, second_counts} =
      service
      |> Map.put("health_check_failures", first_counts)
      |> ServiceCheck.apply_failure_thresholds(health)

    assert second_health["status"] == "passing"
    assert get_in(second_health, ["checks", Access.at(0), "consecutive_failures"]) == 2

    {third_health, _third_counts} =
      service
      |> Map.put("health_check_failures", second_counts)
      |> ServiceCheck.apply_failure_thresholds(health)

    assert third_health["status"] == "critical"
    assert get_in(third_health, ["checks", Access.at(0), "status"]) == "critical"
    assert get_in(third_health, ["checks", Access.at(0), "consecutive_failures"]) == 3
  end

  test "passing checks reset failure thresholds" do
    service = %{
      "checks" => [%{"name" => "ready", "type" => "http", "failures_before_critical" => 2}],
      "health_check_failures" => %{"ready" => 1}
    }

    health = %{
      "status" => "passing",
      "checks" => [%{"name" => "ready", "type" => "http", "status" => "passing"}]
    }

    {updated_health, counts} = ServiceCheck.apply_failure_thresholds(service, health)

    assert updated_health["status"] == "passing"
    assert counts == %{}
  end

  test "grpc checks report critical when the health endpoint is unavailable" do
    started_at = System.monotonic_time(:millisecond)

    report =
      ServiceCheck.check_service(%{
        "id" => "svc-grpc",
        "name" => "grpc-api",
        "address" => "127.0.0.1",
        "port" => unused_port(),
        "checks" => [%{"name" => "grpc", "type" => "grpc", "timeout_ms" => 100}]
      })

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert report["status"] == "critical"
    assert get_in(report, ["checks", Access.at(0), "type"]) == "grpc"
    assert elapsed_ms < 1_000
  end

  test "grpc checks disconnect successful health channels" do
    port = unused_port()

    start_supervised!(
      {GRPC.Server.Supervisor,
       endpoint: HealthEndpoint, port: port, start_server: true, ip: {127, 0, 0, 1}}
    )

    links_before = process_links()

    report =
      ServiceCheck.check_service(%{
        "id" => "svc-grpc-live",
        "name" => "grpc-api",
        "address" => "127.0.0.1",
        "port" => port,
        "checks" => [%{"name" => "grpc", "type" => "grpc", "timeout_ms" => 1_000}]
      })

    assert report["status"] == "passing"

    assert_eventually(fn ->
      process_links() == links_before
    end)
  end

  defp start_http_server(response) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listen_socket)

    spawn_link(fn ->
      with {:ok, socket} <- :gen_tcp.accept(listen_socket, 5_000) do
        _ = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
      end

      :gen_tcp.close(listen_socket)
    end)

    port
  end

  defp start_tcp_server do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listen_socket)

    spawn_link(fn ->
      with {:ok, socket} <- :gen_tcp.accept(listen_socket, 5_000) do
        :gen_tcp.close(socket)
      end

      :gen_tcp.close(listen_socket)
    end)

    port
  end

  defp unused_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp process_links do
    self()
    |> Process.info(:links)
    |> elem(1)
    |> MapSet.new()
  end

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    started_at = System.monotonic_time(:millisecond)
    do_assert_eventually(fun, started_at, timeout_ms)
  end

  defp do_assert_eventually(fun, started_at, timeout_ms) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) - started_at > timeout_ms ->
        flunk("condition was not met before timeout")

      true ->
        Process.sleep(10)
        do_assert_eventually(fun, started_at, timeout_ms)
    end
  end
end
