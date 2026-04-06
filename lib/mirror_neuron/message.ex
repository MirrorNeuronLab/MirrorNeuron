defmodule MirrorNeuron.Message do
  @spec_version "mn-msg/1"
  @default_class "event"
  @default_content_type "application/json"
  @default_content_encoding "identity"
  @json_content_types MapSet.new(["application/json", "text/json"])
  @ndjson_content_types MapSet.new([
                          "application/x-ndjson",
                          "application/jsonl",
                          "application/ndjson"
                        ])
  @legacy_reserved_keys MapSet.new([
                          "message_id",
                          "job_id",
                          "from",
                          "to",
                          "type",
                          "class",
                          "timestamp",
                          "correlation_id",
                          "causation_id",
                          "attempt",
                          "priority",
                          "ttl_ms",
                          "content_type",
                          "content_encoding",
                          "headers",
                          "artifacts",
                          "stream",
                          "payload",
                          "body",
                          "envelope"
                        ])

  def spec_version, do: @spec_version

  def normalize(message, opts \\ [])

  def normalize(message, opts) when is_map(message) do
    stringified = stringify_keys(message)

    normalized =
      if Map.has_key?(stringified, "envelope") do
        normalize_spec_message(stringified, opts)
      else
        normalize_legacy_message(stringified, opts)
      end

    {:ok, normalized}
  rescue
    error -> {:error, Exception.message(error)}
  end

  def normalize(_message, _opts), do: {:error, "message must be a map"}

  def normalize!(message, opts \\ []) do
    case normalize(message, opts) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def envelope(message), do: normalize!(message)["envelope"]
  def headers(message), do: normalize!(message)["headers"]
  def body(message), do: normalize!(message)["body"]
  def artifacts(message), do: normalize!(message)["artifacts"]
  def stream(message), do: normalize!(message)["stream"]

  def id(message), do: get_in(normalize!(message), ["envelope", "message_id"])
  def job_id(message), do: get_in(normalize!(message), ["envelope", "job_id"])
  def from(message), do: get_in(normalize!(message), ["envelope", "from"])
  def to(message), do: get_in(normalize!(message), ["envelope", "to"])
  def type(message), do: get_in(normalize!(message), ["envelope", "type"])
  def class(message), do: get_in(normalize!(message), ["envelope", "class"])
  def content_type(message), do: get_in(normalize!(message), ["envelope", "content_type"])
  def content_encoding(message), do: get_in(normalize!(message), ["envelope", "content_encoding"])
  def correlation_id(message), do: get_in(normalize!(message), ["envelope", "correlation_id"])
  def causation_id(message), do: get_in(normalize!(message), ["envelope", "causation_id"])

  def json_encode(message), do: message |> normalize!() |> Jason.encode()
  def json_encode!(message), do: message |> normalize!() |> Jason.encode!()

  def json_decode(binary) when is_binary(binary) do
    with {:ok, decoded} <- Jason.decode(binary) do
      normalize(decoded)
    end
  end

  def ndjson_encode(messages) when is_list(messages) do
    encoded =
      messages
      |> Enum.map(&json_encode!/1)
      |> Enum.join("\n")

    {:ok, encoded <> "\n"}
  rescue
    error -> {:error, Exception.message(error)}
  end

  def ndjson_decode(binary) when is_binary(binary) do
    try do
      messages =
        binary
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> Jason.decode!() |> normalize!() end)

      {:ok, messages}
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  def serialize(message, format \\ :json)
  def serialize(messages, :ndjson) when is_list(messages), do: ndjson_encode(messages)

  def serialize(message, :json) do
    {:ok, json_encode!(message)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  def serialize(message, :erlang_binary) do
    try do
      {:ok, :erlang.term_to_binary(normalize!(message), [:compressed])}
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  def deserialize(binary, format \\ :json)
  def deserialize(binary, :json), do: json_decode(binary)
  def deserialize(binary, :ndjson), do: ndjson_decode(binary)

  def deserialize(binary, :erlang_binary) when is_binary(binary) do
    try do
      {:ok, :erlang.binary_to_term(binary) |> normalize!()}
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  def body_binary(message) do
    normalized = normalize!(message)
    content_type = content_type(normalized)
    content_encoding = content_encoding(normalized)
    body = normalized["body"]

    with {:ok, encoded_body} <- encode_body(body, content_type),
         {:ok, encoded} <- apply_content_encoding(encoded_body, content_encoding) do
      {:ok, encoded}
    end
  end

  def json_body_binary(message) do
    message
    |> body()
    |> Jason.encode()
  end

  def summary(message) do
    normalized = normalize!(message)

    %{
      "message_id" => id(normalized),
      "from" => from(normalized),
      "to" => to(normalized),
      "type" => type(normalized),
      "class" => class(normalized),
      "content_type" => content_type(normalized),
      "content_encoding" => content_encoding(normalized),
      "stream" => stream(normalized)
    }
  end

  def new(job_id, from, to, type, body, opts \\ []) do
    normalize!(%{
      "envelope" => %{
        "job_id" => job_id,
        "from" => from,
        "to" => to,
        "type" => type,
        "class" => Keyword.get(opts, :class, @default_class),
        "timestamp" => Keyword.get(opts, :timestamp, MirrorNeuron.Runtime.timestamp()),
        "correlation_id" => Keyword.get(opts, :correlation_id, unique_id()),
        "causation_id" => Keyword.get(opts, :causation_id),
        "attempt" => Keyword.get(opts, :attempt, 1),
        "priority" => Keyword.get(opts, :priority, 100),
        "ttl_ms" => Keyword.get(opts, :ttl_ms),
        "content_type" => Keyword.get(opts, :content_type, @default_content_type),
        "content_encoding" => Keyword.get(opts, :content_encoding, @default_content_encoding)
      },
      "headers" => Keyword.get(opts, :headers, %{}),
      "body" => body,
      "artifacts" => Keyword.get(opts, :artifacts, []),
      "stream" => Keyword.get(opts, :stream)
    })
  end

  defp normalize_spec_message(message, opts) do
    envelope =
      message
      |> Map.get("envelope", %{})
      |> stringify_keys()
      |> fill_envelope_defaults(opts)

    %{
      "envelope" => envelope,
      "headers" => normalize_headers(Map.get(message, "headers", %{})),
      "body" => normalize_body(Map.get(message, "body")),
      "artifacts" => normalize_artifacts(Map.get(message, "artifacts", [])),
      "stream" => normalize_stream(Map.get(message, "stream"))
    }
  end

  defp normalize_legacy_message(message, opts) do
    payload =
      cond do
        Map.has_key?(message, "body") -> Map.get(message, "body")
        Map.has_key?(message, "payload") -> Map.get(message, "payload")
        true -> Map.drop(message, MapSet.to_list(@legacy_reserved_keys))
      end

    envelope =
      message
      |> Map.take([
        "message_id",
        "job_id",
        "from",
        "to",
        "type",
        "class",
        "timestamp",
        "correlation_id",
        "causation_id",
        "attempt",
        "priority",
        "ttl_ms",
        "content_type",
        "content_encoding"
      ])
      |> fill_envelope_defaults(opts)

    %{
      "envelope" => envelope,
      "headers" => normalize_headers(Map.get(message, "headers", %{})),
      "body" => normalize_body(payload),
      "artifacts" => normalize_artifacts(Map.get(message, "artifacts", [])),
      "stream" => normalize_stream(Map.get(message, "stream"))
    }
  end

  defp fill_envelope_defaults(envelope, opts) do
    %{
      "spec_version" => @spec_version,
      "message_id" =>
        Map.get(envelope, "message_id", Keyword.get(opts, :message_id, unique_id())),
      "job_id" => Map.get(envelope, "job_id", Keyword.get(opts, :job_id)),
      "from" => Map.get(envelope, "from", Keyword.get(opts, :from, "runtime")),
      "to" => Map.get(envelope, "to", Keyword.get(opts, :to)),
      "type" => Map.get(envelope, "type", Keyword.get(opts, :type, "command")),
      "class" => Map.get(envelope, "class", Keyword.get(opts, :class, @default_class)),
      "timestamp" =>
        Map.get(
          envelope,
          "timestamp",
          Keyword.get(opts, :timestamp, MirrorNeuron.Runtime.timestamp())
        ),
      "correlation_id" =>
        Map.get(envelope, "correlation_id", Keyword.get(opts, :correlation_id, unique_id())),
      "causation_id" => Map.get(envelope, "causation_id", Keyword.get(opts, :causation_id)),
      "attempt" => Map.get(envelope, "attempt", Keyword.get(opts, :attempt, 1)),
      "priority" => Map.get(envelope, "priority", Keyword.get(opts, :priority, 100)),
      "ttl_ms" => Map.get(envelope, "ttl_ms", Keyword.get(opts, :ttl_ms)),
      "content_type" =>
        Map.get(envelope, "content_type", Keyword.get(opts, :content_type, @default_content_type)),
      "content_encoding" =>
        Map.get(
          envelope,
          "content_encoding",
          Keyword.get(opts, :content_encoding, @default_content_encoding)
        )
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_headers(headers) when is_map(headers), do: stringify_keys(headers)
  defp normalize_headers(_), do: %{}

  defp normalize_artifacts(artifacts) when is_list(artifacts),
    do: Enum.map(artifacts, &stringify_keys/1)

  defp normalize_artifacts(_), do: []

  defp normalize_stream(nil), do: nil
  defp normalize_stream(stream) when is_map(stream), do: stringify_keys(stream)
  defp normalize_stream(_), do: nil

  defp normalize_body(body) when is_map(body), do: stringify_keys(body)
  defp normalize_body(body) when is_list(body), do: Enum.map(body, &normalize_body/1)
  defp normalize_body(body), do: body

  defp encode_body(body, content_type) do
    cond do
      MapSet.member?(@json_content_types, content_type) ->
        Jason.encode(body)

      MapSet.member?(@ndjson_content_types, content_type) ->
        encode_ndjson_body(body)

      content_type == "application/octet-stream" and is_binary(body) ->
        {:ok, body}

      true ->
        Jason.encode(body)
    end
  end

  defp encode_ndjson_body(body) when is_binary(body), do: {:ok, body}

  defp encode_ndjson_body(body) when is_list(body) do
    lines =
      body
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    {:ok, lines <> "\n"}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp encode_ndjson_body(body) do
    {:ok, Jason.encode!(body) <> "\n"}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp apply_content_encoding(body, "identity"), do: {:ok, body}
  defp apply_content_encoding(body, "gzip"), do: {:ok, :zlib.gzip(body)}

  defp apply_content_encoding(_body, encoding),
    do: {:error, "unsupported content_encoding #{inspect(encoding)}"}

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
      {normalized_key, stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp unique_id do
    10
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
