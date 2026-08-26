defmodule MirrorNeuron.ServicePreflightTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.{JobBundle, Manifest, ServicePreflight}

  test "checks required external services after resolving bundle config templates" do
    port =
      start_http_server("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")

    root = bundle_root(%{"llm" => %{"api_base" => "http://127.0.0.1:#{port}"}})

    bundle =
      bundle!(root, %{
        "required_services" => [
          %{
            "name" => "ollama",
            "origin" => "external",
            "checks" => [
              %{
                "name" => "tags",
                "type" => "http",
                "url" => "${config.llm.api_base}/api/tags",
                "contains" => "ok"
              }
            ]
          }
        ]
      })

    assert :ok = ServicePreflight.run(bundle)
  after
    cleanup_bundle_root()
  end

  test "failed required services produce validation reports with redacted details" do
    root = bundle_root(%{"llm" => %{"api_base" => "http://127.0.0.1:#{unused_port()}"}})

    bundle =
      bundle!(root, %{
        "required_services" => [
          %{
            "name" => "ollama",
            "origin" => "external",
            "checks" => [
              %{
                "name" => "tags",
                "type" => "http",
                "url" => "${config.llm.api_base}/api/tags?api_key=secret-token",
                "timeout_ms" => 50
              }
            ]
          }
        ]
      })

    assert {:error, "service_requirements_not_met: " <> encoded} = ServicePreflight.run(bundle)
    assert {:ok, report} = Jason.decode(encoded)
    assert report["ok"] == false
    assert hd(report["issues"])["code"] == "service.health_failed"
    refute encoded =~ "secret-token"
  after
    cleanup_bundle_root()
  end

  test "optional registry-backed services do not block when the registry is unavailable" do
    bundle =
      bundle!(nil, %{
        "required_services" => [%{"name" => "optional-vector-db", "required" => false}]
      })

    assert {:ok, report} = ServicePreflight.check_services(bundle.manifest.required_services)
    assert report["ok"] == true
    assert [%{"status" => status}] = report["results"]
    assert status in ["optional_missing", "registry_unavailable"]
  end

  test "force metadata skips service preflight" do
    bundle =
      bundle!(nil, %{
        "metadata" => %{"mn_validation" => %{"force" => true}},
        "required_services" => [
          %{
            "name" => "down-api",
            "address" => "127.0.0.1",
            "port" => unused_port(),
            "checks" => [%{"name" => "tcp", "type" => "tcp", "timeout_ms" => 50}]
          }
        ]
      })

    assert :ok = ServicePreflight.run(bundle)
  end

  test "incomplete direct service addresses fail instead of passing without checks" do
    bundle =
      bundle!(nil, %{
        "required_services" => [
          %{
            "name" => "incomplete-api",
            "origin" => "external",
            "address" => "127.0.0.1"
          }
        ]
      })

    assert {:error, "service_requirements_not_met: " <> _encoded} = ServicePreflight.run(bundle)
  end

  defp bundle!(root, extra) do
    manifest =
      %{
        "apiVersion" => "mn.workflow/v1",
        "kind" => "Workflow",
        "manifest_version" => "1.0",
        "graph_id" => "service-preflight",
        "job_name" => "service-preflight",
        "entrypoints" => ["worker"],
        "flow" => %{
          "nodes" => [%{"node_id" => "worker", "agent_type" => "executor", "role" => "root"}],
          "edges" => []
        },
        "policies" => %{"recovery_mode" => "local_restart"}
      }
      |> Map.merge(extra)

    assert {:ok, manifest} = Manifest.load(manifest)
    %JobBundle{root_path: root, manifest: manifest}
  end

  defp bundle_root(config) do
    root =
      Path.join(System.tmp_dir!(), "mn-service-preflight-#{System.unique_integer([:positive])}")

    Process.put(:service_preflight_root, root)
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join([root, "config", "default.json"]), Jason.encode!(config))
    root
  end

  defp cleanup_bundle_root do
    if root = Process.delete(:service_preflight_root), do: File.rm_rf(root)
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
end
