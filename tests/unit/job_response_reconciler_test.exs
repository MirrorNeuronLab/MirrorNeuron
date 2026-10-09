defmodule MirrorNeuron.Runtime.JobResponseReconcilerTest do
  use ExUnit.Case, async: false

  alias MirrorNeuron.Runtime.JobResponseReconciler

  test "native transport shutdown notifications preserve the reconciler and subsequent work" do
    pid = Process.whereis(JobResponseReconciler)
    assert is_pid(pid)
    state = :sys.get_state(pid)
    monitor = Process.monitor(pid)
    stream = make_ref()

    send(pid, {:gun_down, self(), :http2, :normal, []})
    send(pid, {:gun_down, self(), :http2, :closed, [stream]})
    send(pid, {:gun_error, self(), stream, :closed})

    # A synchronous system request is a mailbox barrier for the notifications.
    assert :sys.get_state(pid) == state
    assert Process.whereis(JobResponseReconciler) == pid
    refute_received {:DOWN, ^monitor, :process, ^pid, _reason}

    assert :ok = JobResponseReconciler.reconcile_async()
    assert :sys.get_state(pid) == state
    assert Process.whereis(JobResponseReconciler) == pid
    Process.demonitor(monitor, [:flush])
  end
end
