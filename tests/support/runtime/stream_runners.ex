defmodule MirrorNeuron.RuntimeTest.StreamProducerRunner do
  def run(_payload, _config, opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    agent_id = Keyword.fetch!(opts, :agent_id)

    {:ok,
     %{
       "sandbox_name" => "producer",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "emit_messages" => [
             %{
               "type" => "telemetry_chunk",
               "body" => "{\"value\":10}\n",
               "class" => "stream",
               "content_type" => "application/x-ndjson",
               "content_encoding" => "identity",
               "stream" => %{
                 "stream_id" => "#{job_id}:#{agent_id}",
                 "seq" => 1,
                 "open" => true,
                 "close" => false
               }
             },
             %{
               "type" => "telemetry_chunk",
               "body" => "{\"value\":90}\n",
               "class" => "stream",
               "content_type" => "application/x-ndjson",
               "content_encoding" => "identity",
               "stream" => %{
                 "stream_id" => "#{job_id}:#{agent_id}",
                 "seq" => 2,
                 "open" => false,
                 "close" => true,
                 "eof" => true
               }
             }
           ]
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.StreamDetectorRunner do
  def run(_payload, _config, opts) do
    message = Keyword.fetch!(opts, :message)
    state = Keyword.get(opts, :agent_state, %{})
    count = Map.get(state, "count", 0) + 1

    completion =
      if get_in(message, ["stream", "close"]) do
        %{"chunks_received" => count, "peak_detected" => true}
      end

    {:ok,
     %{
       "sandbox_name" => "detector",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "next_state" => %{"count" => count},
           "events" => [%{"type" => "stream_chunk_processed", "payload" => %{"count" => count}}],
           "complete_run" => completion
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.SlowBackpressureRunner do
  def run(payload, _config, _opts) do
    Process.sleep(300)

    {:ok,
     %{
       "sandbox_name" => "slow-backpressure",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "events" => [
             %{
               "type" => "slow_event_processed",
               "payload" => %{"value" => Map.get(payload, "value")}
             }
           ]
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.BlockedAnalysisRunner do
  def run(_payload, _config, _opts) do
    owner = :global.whereis_name({__MODULE__, :test_owner})
    send(owner, {:analysis_blocked, self()})

    receive do
      :release_analysis -> :ok
    after
      10_000 -> :ok
    end

    {:ok, %{"exit_code" => 0, "stdout" => "{}", "stderr" => "", "logs" => ""}}
  end
end

defmodule MirrorNeuron.RuntimeTest.PromptControlRunner do
  def run(_payload, _config, _opts) do
    {:ok,
     %{
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "events" => [
             %{"type" => "prompt_control_applied", "payload" => %{"applied" => true}}
           ]
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end
