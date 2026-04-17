defmodule MirrorNeuron.API.Router do
  use Plug.Router
  require Logger

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json, :multipart],
    length: 50_000_000,
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  def init(options) do
    options
  end

  # Health Check
  get "/api/v1/health" do
    send_json(conn, 200, %{status: "ok"})
  end

  # System Summary
  get "/api/v1/system/summary" do
    case MirrorNeuron.cluster_overview() do
      {:ok, summary} ->
        send_json(conn, 200, summary)

      {:error, reason} ->
        send_error(conn, 500, reason)
    end
  end

  # Upload and Validate Bundle
  post "/api/v1/bundles/upload" do
    case conn.body_params["bundle"] do
      %Plug.Upload{path: tmp_path, filename: filename} ->
        # Create a unique directory for extraction
        bundle_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        target_dir = Path.join(System.tmp_dir!(), "mn_bundle_#{bundle_id}")
        File.mkdir_p!(target_dir)

        # Unzip
        case :zip.extract(to_charlist(tmp_path), cwd: to_charlist(target_dir)) do
          {:ok, _} ->
            # Let's check if there is a root folder inside the zip
            # If manifest.json is directly inside or inside a subfolder
            manifest_path = Path.join(target_dir, "manifest.json")

            real_target_dir =
              if File.exists?(manifest_path) do
                target_dir
              else
                # Try to find a subfolder
                case File.ls!(target_dir) do
                  [subfolder] ->
                    subpath = Path.join(target_dir, subfolder)

                    if File.dir?(subpath) and File.exists?(Path.join(subpath, "manifest.json")) do
                      subpath
                    else
                      target_dir
                    end

                  _ ->
                    target_dir
                end
              end

            # Validate using JobBundle
            case MirrorNeuron.JobBundle.load(real_target_dir) do
              {:ok, bundle} ->
                send_json(conn, 200, %{bundle_path: real_target_dir, manifest: bundle.manifest})

              {:error, reason} ->
                File.rm_rf!(target_dir)
                send_error(conn, 400, "Invalid bundle: #{inspect(reason)}")
            end

          {:error, reason} ->
            File.rm_rf!(target_dir)
            send_error(conn, 400, "Failed to unzip: #{inspect(reason)}")
        end

      _ ->
        send_error(conn, 400, "Missing 'bundle' file upload")
    end
  end

  # Create Job
  post "/api/v1/jobs" do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        send_error(conn, 400, "Invalid or missing JSON payload")

      manifest when map_size(manifest) == 0 ->
        send_error(conn, 400, "Empty JSON payload")

      manifest ->
        case MirrorNeuron.run_manifest(manifest) do
          {:ok, job_id} ->
            send_json(conn, 201, %{id: job_id, status: "pending"})

          {:error, reason} ->
            send_error(conn, 400, reason)
        end
    end
  end

  # List Jobs
  get "/api/v1/jobs" do
    conn = fetch_query_params(conn)
    opts = parse_list_opts(conn.query_params)

    case MirrorNeuron.list_jobs(opts) do
      {:ok, jobs} ->
        send_json(conn, 200, %{data: jobs})

      {:error, reason} ->
        send_error(conn, 500, reason)
    end
  end

  # Get Job Details
  get "/api/v1/jobs/:job_id" do
    case MirrorNeuron.job_details(job_id) do
      {:ok, details} ->
        send_json(conn, 200, details)

      {:error, reason} ->
        handle_job_error(conn, reason)
    end
  end

  # Pause Job
  post "/api/v1/jobs/:job_id/pause" do
    case MirrorNeuron.pause(job_id) do
      :ok ->
        send_json(conn, 200, %{status: "paused", job_id: job_id})

      {:error, reason} ->
        handle_job_error(conn, reason)
    end
  end

  # Resume Job
  post "/api/v1/jobs/:job_id/resume" do
    case MirrorNeuron.resume(job_id) do
      :ok ->
        send_json(conn, 200, %{status: "resumed", job_id: job_id})

      {:error, reason} ->
        handle_job_error(conn, reason)
    end
  end

  # Stop/Cancel Job
  post "/api/v1/jobs/:job_id/cancel" do
    case MirrorNeuron.cancel(job_id) do
      {:ok, status} ->
        send_json(conn, 200, %{status: status, job_id: job_id})

      :ok ->
        send_json(conn, 200, %{status: "cancelled", job_id: job_id})

      {:error, reason} ->
        handle_job_error(conn, reason)
    end
  end

  # Cleanup Jobs
  post "/api/v1/jobs/cleanup" do
    conn = fetch_query_params(conn)

    opts =
      if Map.get(conn.query_params, "all") in ["true", "1"] do
        [all: true]
      else
        []
      end

    case MirrorNeuron.cleanup_jobs(opts) do
      {:ok, result} ->
        send_json(conn, 200, result)

      {:error, reason} ->
        send_error(conn, 500, reason)
    end
  end

  # Get Job Events
  get "/api/v1/jobs/:job_id/events" do
    # Verify job exists first
    case MirrorNeuron.inspect_job(job_id) do
      {:ok, _job} ->
        case MirrorNeuron.events(job_id) do
          {:ok, events} ->
            send_json(conn, 200, %{data: events})

          {:error, reason} ->
            send_error(conn, 500, reason)
        end

      {:error, reason} ->
        handle_job_error(conn, reason)
    end
  end

  # Reload Bundle
  post "/api/v1/bundles/:bundle_id/reload" do
    case MirrorNeuron.Bundle.Manager.reload(bundle_id, "api_request") do
      {:ok, resp} ->
        send_json(conn, 200, resp)

      {:error, :not_found} ->
        send_error(conn, 404, "Bundle #{bundle_id} not found")

      {:error, reason} ->
        send_error(conn, 500, reason)
    end
  end

  # Add Node
  post "/api/v1/nodes/:node_name" do
    case MirrorNeuron.add_node(node_name) do
      {:ok, resp} ->
        send_json(conn, 201, resp)

      {:error, reason} ->
        send_error(conn, 500, reason)
    end
  end

  # Remove Node
  delete "/api/v1/nodes/:node_name" do
    case MirrorNeuron.remove_node(node_name) do
      {:ok, resp} ->
        send_json(conn, 200, resp)

      {:error, reason} ->
        send_error(conn, 500, reason)
    end
  end

  # List Nodes
  get "/api/v1/nodes" do
    send_json(conn, 200, %{data: MirrorNeuron.inspect_nodes()})
  end

  match _ do
    send_error(conn, 404, "Not Found")
  end

  # --- Helpers ---

  defp send_json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp send_error(conn, status, reason) do
    msg =
      cond do
        is_binary(reason) -> reason
        is_exception(reason) -> Exception.message(reason)
        true -> inspect(reason)
      end

    send_json(conn, status, %{error: msg})
  end

  defp handle_job_error(conn, reason) do
    reason_str = to_string(reason)

    if String.contains?(reason_str, "was not found") or
         String.contains?(reason_str, "is not running in the connected cluster") do
      send_error(conn, 404, reason)
    else
      send_error(conn, 500, reason)
    end
  end

  defp parse_list_opts(params) do
    opts = []

    opts =
      case Integer.parse(Map.get(params, "limit", "")) do
        {n, _} when n > 0 -> Keyword.put(opts, :limit, n)
        _ -> opts
      end

    opts =
      case Map.get(params, "include_terminal") do
        "false" -> Keyword.put(opts, :include_terminal, false)
        # defaults to true in Monitor.list_jobs
        _ -> opts
      end

    opts
  end
end
