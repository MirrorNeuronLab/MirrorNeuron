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
  def spec_version, do: @spec_version

  def normalize(message, opts \\ [])

  def normalize(message, opts) when is_map(message) do
    normalized =
      if normalized_message?(message, opts) do
        message
      else
        stringified = stringify_keys(message)

        if not Map.has_key?(stringified, "envelope") do
          raise ArgumentError, "message must use the mn-msg/1 envelope"
        end

        normalize_spec_message(stringified, opts)
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

  def envelope(message), do: normalized_or_raise!(message)["envelope"]
  def headers(message), do: normalized_or_raise!(message)["headers"]
  def body(message), do: normalized_or_raise!(message)["body"]
  def artifacts(message), do: normalized_or_raise!(message)["artifacts"]
  def stream(message), do: normalized_or_raise!(message)["stream"]

  def id(message), do: envelope_value(message, "message_id")
  def job_id(message), do: envelope_value(message, "job_id")
  def from(message), do: envelope_value(message, "from")
  def to(message), do: envelope_value(message, "to")
  def type(message), do: envelope_value(message, "type")
  def class(message), do: envelope_value(message, "class")
  def content_type(message), do: envelope_value(message, "content_type")
  def content_encoding(message), do: envelope_value(message, "content_encoding")
  def correlation_id(message), do: envelope_value(message, "correlation_id")
  def causation_id(message), do: envelope_value(message, "causation_id")

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
    envelope = normalized["envelope"]
    content_type = envelope["content_type"]
    content_encoding = envelope["content_encoding"]
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
    envelope = normalized["envelope"]

    %{
      "message_id" => envelope["message_id"],
      "from" => envelope["from"],
      "to" => envelope["to"],
      "type" => envelope["type"],
      "class" => envelope["class"],
      "content_type" => envelope["content_type"],
      "content_encoding" => envelope["content_encoding"],
      "stream" => normalized["stream"]
    }
  end

  def new(job_id, from, to, type, body, opts \\ []) do
    normalize!(%{
      "envelope" => %{
        "message_id" => Keyword.get(opts, :message_id),
        "job_id" => job_id,
        "from" => from,
        "to" => to,
        "type" => type,
        "class" => Keyword.get(opts, :class, @default_class),
        "timestamp" => Keyword.get_lazy(opts, :timestamp, &MirrorNeuron.Runtime.timestamp/0),
        "correlation_id" => Keyword.get_lazy(opts, :correlation_id, &unique_id/0),
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

  defp fill_envelope_defaults(envelope, opts) do
    %{
      "spec_version" => @spec_version,
      "message_id" =>
        envelope_or_opt_lazy(envelope, "message_id", opts, :message_id, &unique_id/0),
      "job_id" => Map.get(envelope, "job_id", Keyword.get(opts, :job_id)),
      "from" => Map.get(envelope, "from", Keyword.get(opts, :from, "runtime")),
      "to" => Map.get(envelope, "to", Keyword.get(opts, :to)),
      "type" => Map.get(envelope, "type", Keyword.get(opts, :type, "command")),
      "class" => Map.get(envelope, "class", Keyword.get(opts, :class, @default_class)),
      "timestamp" =>
        envelope_or_opt_lazy(
          envelope,
          "timestamp",
          opts,
          :timestamp,
          &MirrorNeuron.Runtime.timestamp/0
        ),
      "correlation_id" =>
        envelope_or_opt_lazy(
          envelope,
          "correlation_id",
          opts,
          :correlation_id,
          &unique_id/0
        ),
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

  defp normalized_or_raise!(message) do
    if normalized_message?(message, []) do
      message
    else
      normalize!(message)
    end
  end

  defp envelope_value(%{"envelope" => envelope} = message, key)
       when is_map(envelope) do
    if normalized_message?(message, []),
      do: envelope[key],
      else: get_in(normalize!(message), ["envelope", key])
  end

  defp envelope_value(message, key), do: get_in(normalize!(message), ["envelope", key])

  defp normalized_message?(
         %{
           "envelope" => %{"spec_version" => @spec_version},
           "headers" => headers,
           "artifacts" => artifacts
         },
         []
       )
       when is_map(headers) and is_list(artifacts),
       do: true

  defp normalized_message?(_message, _opts), do: false

  defp envelope_or_opt_lazy(envelope, envelope_key, opts, opt_key, default_fun) do
    case Map.fetch(envelope, envelope_key) do
      {:ok, value} when not is_nil(value) ->
        value

      _missing_or_nil ->
        Keyword.get_lazy(opts, opt_key, default_fun)
    end
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
