defmodule MirrorNeuron.RuntimeTest.DelayedCompleteRunner do
  def run(_payload, _config, _opts) do
    Process.sleep(1_000)

    {:ok,
     %{
       "sandbox_name" => "delayed-complete",
       "exit_code" => 0,
       "stdout" => Jason.encode!(%{"complete_run" => %{"done" => true}}),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.SlowServiceStop do
  def run(payload, config, opts),
    do: MirrorNeuron.RuntimeTest.LongSleepRunner.run(payload, config, opts)

  def resumable_after_stop?(_config), do: true
  def prepared_key(_config, :pause), do: :test_project
  def prepared_key(_config, _transition), do: nil

  def stop_prepared(_config) do
    send(__MODULE__, {:stopping, self()})

    receive do
      {:stop_result, result} -> result
    after
      5_000 -> {:error, :missing_test_receipt}
    end
  end
end

defmodule MirrorNeuron.RuntimeTest.LongSleepRunner do
  def run(_payload, _config, _opts) do
    Process.sleep(30_000)

    {:ok,
     %{
       "sandbox_name" => "long-sleep",
       "exit_code" => 0,
       "stdout" => Jason.encode!(%{"complete_run" => %{"done" => true}}),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.PauseResumeInvocationCounter do
  @key __MODULE__

  def reset do
    :persistent_term.put(@key, :atomics.new(1, []))
    :ok
  end

  def next do
    @key
    |> :persistent_term.get()
    |> :atomics.add_get(1, 1)
  end

  def current, do: :atomics.get(:persistent_term.get(@key), 1)
end

defmodule MirrorNeuron.RuntimeTest.PauseResumeRunner do
  alias MirrorNeuron.RuntimeTest.PauseResumeInvocationCounter

  def run(_payload, _config, _opts) do
    case PauseResumeInvocationCounter.next() do
      1 ->
        Process.sleep(30_000)

        {:ok,
         %{
           "sandbox_name" => "pause-resume-interrupted",
           "exit_code" => 0,
           "stdout" => "{}",
           "stderr" => "",
           "logs" => ""
         }}

      invocation ->
        {:ok,
         %{
           "sandbox_name" => "pause-resume-completed",
           "exit_code" => 0,
           "stdout" =>
             Jason.encode!(%{
               "emit_messages" => [
                 %{"type" => "workflow_done", "body" => %{"resumed" => true}}
               ],
               "complete_step" => %{"resumed" => true, "invocation" => invocation}
             }),
           "stderr" => "",
           "logs" => ""
         }}
    end
  end
end

defmodule MirrorNeuron.RuntimeTest.SafeRetryRunner do
  def run(payload, _config, opts) do
    {:ok,
     %{
       "sandbox_name" => "safe-retry",
       "exit_code" => 0,
       "stdout" =>
         Jason.encode!(%{
           "complete_run" => %{
             "retried" => true,
             "payload" => payload,
             "attempt" => Keyword.get(opts, :attempt)
           }
         }),
       "stderr" => "",
       "logs" => ""
     }}
  end
end

defmodule MirrorNeuron.RuntimeTest.HibernateRetryCounter do
  @key __MODULE__

  def init do
    :persistent_term.put(@key, :atomics.new(1, []))
    :atomics.put(:persistent_term.get(@key), 1, 0)
    :ok
  end

  def next_invocation do
    @key
    |> :persistent_term.get()
    |> :atomics.add_get(1, 1)
  end

  def invocations do
    @key
    |> :persistent_term.get()
    |> :atomics.get(1)
  end
end

defmodule MirrorNeuron.RuntimeTest.HibernateRetryRunner do
  alias MirrorNeuron.RuntimeTest.HibernateRetryCounter

  def run(payload, _config, opts) do
    case HibernateRetryCounter.next_invocation() do
      1 ->
        {:error, %{"error" => "resource temporarily unavailable after wake"}}

      invocation ->
        {:ok,
         %{
           "sandbox_name" => "hibernate-retry",
           "exit_code" => 0,
           "stdout" =>
             Jason.encode!(%{
               "complete_run" => %{
                 "invocation" => invocation,
                 "message_id" => opts |> Keyword.fetch!(:message) |> MirrorNeuron.Message.id(),
                 "payload" => payload
               }
             }),
           "stderr" => "",
           "logs" => ""
         }}
    end
  end
end
