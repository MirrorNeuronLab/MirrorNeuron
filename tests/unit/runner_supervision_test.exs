defmodule MirrorNeuron.Runner.SupervisionTest do
  use ExUnit.Case, async: false
  alias MirrorNeuron.Runner.HostLocal

  defp run(script, timeout \\ 0.5) do
    python = System.find_executable("python3")

    config = %{
      "timeout_seconds" => timeout,
      "environment" => %{"MN_WORKFLOW_ATTEMPT_ID" => "attempt"}
    }

    HostLocal.stream_command([python, "-u", "-c", script], [], File.cwd!(), config, [])
  end

  test "real port receipts exclude preparation longer than the command limit" do
    script = ~S"""
    import json, time
    def event(kind):
        payload = {"attempt_id":"attempt", "preparation_id":"model", "kind":"model", "timeout_ms":5000}
        print('__MN_EVENT__'+json.dumps({"type":"runtime_preparation_"+kind,"payload":payload}), flush=True)
    event('started')
    time.sleep(1.2)
    event('finished')
    print('finished')
    """

    # stream_command gets the same environment as its prepared config.
    assert {:ok, "finished\n", 0} =
             HostLocal.stream_command(
               [System.find_executable("python3"), "-u", "-c", script],
               [{"MN_WORKFLOW_ATTEMPT_ID", "attempt"}],
               File.cwd!(),
               %{"timeout_seconds" => 0.5},
               []
             )
  end

  test "real port progress outlives its original command deadline" do
    assert {:ok, "finished\n", 0} =
             run(~S"""
             import json, time
             for n in range(12):
                 print('__MN_AGENT_BEACON__'+json.dumps({"source":"agent","pid":7,"progress_sequence":n}), flush=True)
                 time.sleep(.1)
             print('finished')
             """)
  end

  test "a live process with unchanged progress is terminated" do
    assert {:error, %{"error" => "host local command timed out"}} =
             run(~S"""
             import json, time
             for n in range(50):
                 print('__MN_AGENT_BEACON__'+json.dumps({"source":"agent","pid":7,"progress_sequence":1}), flush=True)
                 time.sleep(.1)
             """)
  end

  test "a bounded external wait is live through the command limit" do
    assert {:ok, "finished\n", 0} =
             run(~S"""
             import json, time
             print('__MN_AGENT_BEACON__'+json.dumps({"source":"agent","pid":7,"progress_sequence":1,"wait_id":"request","wait_timeout_ms":3000}), flush=True)
             time.sleep(1.2)
             print('finished')
             """)
  end
end
