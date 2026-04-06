defmodule MirrorNeuron.API.Router do
  use Plug.Router
  require Logger

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
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

  # Stop/Cancel Job
  post "/api/v1/jobs/:job_id/cancel" do
    case MirrorNeuron.cancel(job_id) do
      :ok ->
        send_json(conn, 200, %{status: "cancelled", job_id: job_id})

      {:error, reason} ->
        handle_job_error(conn, reason)
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
