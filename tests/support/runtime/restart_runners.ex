defmodule MirrorNeuron.RuntimeTest.CrashOnceCounter do
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> 0 end, name: __MODULE__)
  end

  def next_invocation do
    Agent.get_and_update(__MODULE__, fn count ->
      next = count + 1
      {next, next}
    end)
  end

  def invocations, do: Agent.get(__MODULE__, & &1)
end

defmodule MirrorNeuron.RuntimeTest.CrashOnceRunner do
  alias MirrorNeuron.RuntimeTest.CrashOnceCounter

  def run(_payload, _config, _opts) do
    case CrashOnceCounter.next_invocation() do
      1 ->
        Process.sleep(10_000)

        {:ok,
         %{
           "sandbox_name" => "crash-once",
           "exit_code" => 0,
           "stdout" => "{}",
           "stderr" => "",
           "logs" => ""
         }}

      invocation ->
        {:ok,
         %{
           "sandbox_name" => "crash-once",
           "exit_code" => 0,
           "stdout" =>
             Jason.encode!(%{
               "complete_run" => %{
                 "recovered" => true,
                 "invocation" => invocation
               }
             }),
           "stderr" => "",
           "logs" => ""
         }}
    end
  end
end

defmodule MirrorNeuron.RuntimeTest.CrashTwiceCounter do
  @key __MODULE__

  def init do
    :persistent_term.put(@key, :atomics.new(1, []))
    :atomics.put(:persistent_term.get(@key), 1, 0)
    :ok
  end

  def next_invocation do
    atomics = :persistent_term.get(@key)
    :atomics.add_get(atomics, 1, 1)
  end

  def invocations do
    @key
    |> :persistent_term.get()
    |> :atomics.get(1)
  end
end

defmodule MirrorNeuron.RuntimeTest.CrashTwiceRunner do
  alias MirrorNeuron.RuntimeTest.CrashTwiceCounter

  def run(_payload, _config, _opts) do
    case CrashTwiceCounter.next_invocation() do
      invocation when invocation <= 2 ->
        Process.sleep(10_000)

        {:ok,
         %{
           "sandbox_name" => "crash-twice",
           "exit_code" => 0,
           "stdout" => "{}",
           "stderr" => "",
           "logs" => ""
         }}

      invocation ->
        {:ok,
         %{
           "sandbox_name" => "crash-twice",
           "exit_code" => 0,
           "stdout" =>
             Jason.encode!(%{
               "complete_run" => %{
                 "recovered" => true,
                 "invocation" => invocation
               }
             }),
           "stderr" => "",
           "logs" => ""
         }}
    end
  end
end

defmodule MirrorNeuron.RuntimeTest.FailOnceCounter do
  @key __MODULE__

  def init do
    :persistent_term.put(@key, :atomics.new(1, []))
    :atomics.put(:persistent_term.get(@key), 1, 0)
    :ok
  end

  def next_invocation do
    atomics = :persistent_term.get(@key)
    :atomics.add_get(atomics, 1, 1)
  end

  def invocations do
    @key
    |> :persistent_term.get()
    |> :atomics.get(1)
  end
end

defmodule MirrorNeuron.RuntimeTest.FailOnceServiceRunner do
  alias MirrorNeuron.RuntimeTest.FailOnceCounter

  def run(_payload, _config, _opts) do
    case FailOnceCounter.next_invocation() do
      1 ->
        {:error,
         %{
           "exit_code" => 3,
           "error" => "temporary service bind failure",
           "logs" => ""
         }}

      _invocation ->
        Process.sleep(10_000)

        {:ok,
         %{
           "sandbox_name" => "fail-once-service",
           "exit_code" => 0,
           "stdout" => "{}",
           "stderr" => "",
           "logs" => ""
         }}
    end
  end
end
