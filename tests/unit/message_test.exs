defmodule MirrorNeuron.MessageTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.Message

  test "normalizes a legacy payload map into the v1 message shape" do
    legacy = %{
      "message_id" => "msg-1",
      "from" => "router",
      "to" => "sink",
      "type" => "result",
      "payload" => %{"value" => 42}
    }

    assert {:ok, normalized} = Message.normalize(legacy, job_id: "job-1")
    assert normalized["envelope"]["spec_version"] == "mn-msg/1"
    assert normalized["envelope"]["job_id"] == "job-1"
    assert normalized["body"] == %{"value" => 42}
    assert normalized["headers"] == %{}
    assert normalized["artifacts"] == []
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
