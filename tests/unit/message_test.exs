defmodule MirrorNeuron.MessageTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Message

  test "rejects flat messages without the mn-msg/1 envelope" do
    flat = %{
      "message_id" => "msg-1",
      "from" => "router",
      "to" => "sink",
      "type" => "result",
      "payload" => %{"value" => 42}
    }

    assert {:error, "message must use the mn-msg/1 envelope"} =
             Message.normalize(flat, job_id: "job-1")
  end

  test "preserves envelope headers artifacts and stream in spec messages" do
    message = %{
      "envelope" => %{
        "message_id" => "msg-2",
        "job_id" => "job-2",
        "from" => "worker",
        "to" => "aggregator",
        "type" => "prime_progress",
        "class" => "stream",
        "content_type" => "application/x-ndjson"
      },
      "headers" => %{"schema_ref" => "com.test.prime", "schema_version" => "1.0.0"},
      "body" => "{\"checked\":10}\n",
      "artifacts" => [%{"artifact_id" => "art-1", "uri" => "file:///tmp/out.json"}],
      "stream" => %{"stream_id" => "stream-1", "seq" => 3, "open" => false, "close" => false}
    }

    assert {:ok, normalized} = Message.normalize(message)
    assert normalized["headers"]["schema_ref"] == "com.test.prime"

    assert normalized["artifacts"] == [
             %{"artifact_id" => "art-1", "uri" => "file:///tmp/out.json"}
           ]

    assert normalized["stream"]["seq"] == 3
    assert Message.class(normalized) == "stream"
    assert Message.content_type(normalized) == "application/x-ndjson"
  end

  test "accessors and summary preserve normalized message values" do
    generated = Message.new("job-generated", "source", "target", "progress", %{})
    assert is_binary(Message.id(generated))
    assert is_binary(Message.correlation_id(generated))

    message =
      Message.new("job-fast", "source", "target", "progress", %{"value" => 1},
        message_id: "msg-fast",
        timestamp: "2026-05-01T00:00:00.000Z",
        correlation_id: "corr-fast",
        headers: %{"schema_ref" => "test.progress"},
        stream: %{"seq" => 1}
      )

    assert Message.id(message) == "msg-fast"
    assert Message.job_id(message) == "job-fast"
    assert Message.from(message) == "source"
    assert Message.to(message) == "target"
    assert Message.type(message) == "progress"
    assert Message.headers(message) == %{"schema_ref" => "test.progress"}

    assert Message.summary(message) == %{
             "message_id" => "msg-fast",
             "from" => "source",
             "to" => "target",
             "type" => "progress",
             "class" => "event",
             "content_type" => "application/json",
             "content_encoding" => "identity",
             "stream" => %{"seq" => 1}
           }
  end

  test "round trips JSON, NDJSON, and compressed erlang binary serialization" do
    message =
      Message.new("job-3", "router", "sink", "result", %{"value" => 123},
        headers: %{"schema_ref" => "com.test.result"}
      )

    assert {:ok, json} = Message.serialize(message, :json)
    assert {:ok, from_json} = Message.deserialize(json, :json)
    assert Message.body(from_json) == %{"value" => 123}

    assert {:ok, ndjson} = Message.serialize([message, message], :ndjson)
    assert {:ok, from_ndjson} = Message.deserialize(ndjson, :ndjson)
    assert length(from_ndjson) == 2
    assert Enum.all?(from_ndjson, &(Message.type(&1) == "result"))

    assert {:ok, binary} = Message.serialize(message, :erlang_binary)
    assert is_binary(binary)
    assert {:ok, from_binary} = Message.deserialize(binary, :erlang_binary)
    assert Message.headers(from_binary)["schema_ref"] == "com.test.result"
  end

  test "encodes NDJSON stream bodies and gzip-compressed JSON bodies" do
    stream_message =
      Message.new("job-4", "worker", "aggregator", "progress", [%{"n" => 1}, %{"n" => 2}],
        class: "stream",
        content_type: "application/x-ndjson"
      )

    assert {:ok, ndjson_body} = Message.body_binary(stream_message)
    assert ndjson_body == "{\"n\":1}\n{\"n\":2}\n"

    compressed =
      Message.new("job-5", "worker", "aggregator", "result", %{"ok" => true},
        content_encoding: "gzip"
      )

    assert {:ok, gzipped} = Message.body_binary(compressed)
    assert is_binary(gzipped)
    assert :zlib.gunzip(gzipped) == "{\"ok\":true}"
  end
end
