defmodule MirrorNeuron.AgentTemplatesTest do
  use ExUnit.Case, async: true

  alias MirrorNeuron.AgentTemplates
  alias MirrorNeuron.AgentTemplates.{Batch, Generic, Map, Reduce, Stream}
  alias MirrorNeuron.Message

  test "generic defaults include config and template type" do
    node = %{config: %{"flag" => true}, type: "stream"}

    defaults = Generic.defaults(node, %{custom: 1})

    assert defaults.config == %{"flag" => true}
    assert defaults.template == "stream"
    assert defaults.custom == 1
  end

  test "template registry normalizes defaults and compatibility aliases" do
    assert AgentTemplates.default_type() == "generic"
    assert AgentTemplates.canonical_type(nil) == "generic"
    assert AgentTemplates.canonical_type("") == "generic"
    assert AgentTemplates.canonical_type("accumulator") == "reduce"
    assert AgentTemplates.supported_type?("batch")
    assert AgentTemplates.supported_for_agent_type?("map", "router")
    refute AgentTemplates.supported_for_agent_type?("stream", "aggregator")
  end

  test "stream template initializes and records chunk progress" do
    node = %{config: %{"stream_id" => "telemetry-1"}, type: "stream"}

    assert {:ok, state0} = Stream.init(node)
    assert state0.stream_id == "telemetry-1"
    assert state0.chunks_received == 0
    assert state0.items_seen == 0

    assert {:ok, state1, actions} = Stream.observe_chunk(4, state0)
    assert state1.chunks_received == 1
    assert state1.items_seen == 4

    assert actions == [
             {:event, :stream_chunk_processed, %{"chunks_received" => 1, "items_seen" => 4}}
           ]
  end

  test "map template initializes and tracks transforms" do
    node = %{config: %{}, type: "map"}

    assert {:ok, state0} = Map.init(node)
    assert state0.processed == 0

    assert {:ok, state1, actions} = Map.record_transform(state0, event_type: :custom_transform)
    assert state1.processed == 1
    assert actions == [{:event, :custom_transform, %{"processed" => 1}}]
  end

  test "reduce template collects messages and completes when threshold reached" do
    node = %{config: %{"complete_after" => 2}, type: "reduce"}
    message1 = Message.new("job-1", "source", "collector", "sample", %{"value" => 1})
    message2 = Message.new("job-1", "source", "collector", "sample", %{"value" => 2})

    assert {:ok, state0} = Reduce.init(node)

    assert {:ok, state1, actions1} =
             Reduce.collect(message1, state0,
               build_result: fn messages, _config, last ->
                 %{"count" => length(messages), "last" => last}
               end
             )

    assert state1.messages == [%{"value" => 1}]
    assert actions1 == [{:event, :reducer_received, %{"count" => 1}}]

    assert {:ok, state2, actions2} =
             Reduce.collect(message2, state1,
               event_type: :custom_reduce,
               extra_actions: [{:event, :checkpointed, %{"ok" => true}}],
               build_result: fn messages, _config, last ->
                 %{"count" => length(messages), "last" => last}
               end
             )

    assert state2.messages == [%{"value" => 1}, %{"value" => 2}]

    assert actions2 == [
             {:event, :custom_reduce, %{"count" => 2}},
             {:event, :checkpointed, %{"ok" => true}},
             {:complete_job, %{"count" => 2, "last" => %{"value" => 2}}}
           ]
  end

  test "batch template buffers items and flushes when batch size is reached" do
    node = %{config: %{"batch_size" => 2}, type: "batch"}

    assert {:ok, state0} = Batch.init(node)
    assert state0.batch == []
    assert state0.batch_size == 2

    assert {:cont, state1, actions1} = Batch.push(%{"item" => 1}, state0)
    assert state1.batch == [%{"item" => 1}]
    assert actions1 == [{:event, :batch_buffered, %{"size" => 1}}]

    assert {:flush, flushed_batch, state2, actions2} = Batch.push(%{"item" => 2}, state1)
    assert flushed_batch == [%{"item" => 1}, %{"item" => 2}]
    assert state2.batch == []
    assert state2.flushed_batches == 1

    assert actions2 == [
             {:event, :batch_buffered, %{"size" => 2, "flushed_batches" => 1}}
           ]
  end
end
