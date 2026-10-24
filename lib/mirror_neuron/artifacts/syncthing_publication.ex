defmodule MirrorNeuron.Artifacts.SyncthingPublication do
  @moduledoc false

  alias MirrorNeuron.Config

  # Docker bind-mount writes do not reliably wake the sidecar's filesystem
  # watcher. Publish only the committed output subtree of this submission.
  def publish(root, directory) do
    enabled =
      Config.string("MN_SYNCTHING_ENABLED", :syncthing_enabled)
      |> String.trim()
      |> String.downcase()

    key = Config.secret("MN_SYNCTHING_API_KEY", :syncthing_api_key)

    if enabled in ["", "0", "false", "no", "n", "off", "disabled"] or is_nil(key) do
      :ok
    else
      relative = Path.relative_to(Path.expand(directory), Path.expand(root))

      if Path.type(relative) != :relative or relative in ["", "."] or
           ".." in Path.split(relative) do
        {:error, :invalid_publication_path}
      else
        host =
          Config.optional_string("MN_SYNCTHING_ADVERTISE_HOST", :syncthing_advertise_host) ||
            "127.0.0.1"

        port = Config.integer("MN_SYNCTHING_GUI_PORT", :syncthing_gui_port)
        folder = Config.string("MN_SYNCTHING_FOLDER_ID", :syncthing_folder_id)

        url =
          URI.to_string(%URI{
            scheme: "http",
            host: host,
            port: port,
            path: "/rest/db/scan",
            query: URI.encode_query(%{"folder" => folder, "sub" => relative})
          })

        request =
          {String.to_charlist(url), [{~c"X-API-Key", String.to_charlist(key)}],
           ~c"application/json", ""}

        case :httpc.request(
               :post,
               request,
               [timeout: 3_000, connect_timeout: 1_000, autoredirect: false],
               []
             ) do
          {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
          _ -> {:error, :syncthing_publication_failed}
        end
      end
    end
  end
end
