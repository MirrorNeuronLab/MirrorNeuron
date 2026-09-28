defmodule MirrorNeuron.Runner.DockerCommand do
  @moduledoc false

  @registry MirrorNeuron.Runner.DockerProcessRegistry

  # Docker exec clients do not own the lifetime of the process in the container.
  # Serialize command startup and cancellation in the invocation's private directory.
  @supervisor """
  import fcntl, os, signal, subprocess, sys, time
  mode, root = sys.argv[1:3]
  os.makedirs(root, exist_ok=True)
  lock = open(os.path.join(root, '.mn-command-lock'), 'a')
  pid_path = os.path.join(root, '.mn-command-pid')
  cancelled = os.path.join(root, '.mn-command-cancelled')
  def stop_group(pid, grace=True):
      try:
          if grace:
              os.killpg(pid, signal.SIGTERM)
              time.sleep(0.2)
          os.killpg(pid, signal.SIGKILL)
      except ProcessLookupError:
          pass
  fcntl.flock(lock, fcntl.LOCK_EX)
  if mode == 'stop':
      open(cancelled, 'a').close()
      if os.path.exists(pid_path):
          with open(pid_path) as record:
              stop_group(int(record.read()))
      sys.exit(0)
  if os.path.exists(cancelled):
      sys.exit(125)
  child = subprocess.Popen(sys.argv[3:], start_new_session=True)
  try:
      with open(pid_path, 'w') as record:
          record.write(str(child.pid))
  except BaseException:
      stop_group(child.pid, grace=False)
      child.wait()
      raise
  fcntl.flock(lock, fcntl.LOCK_UN)
  # Retain the child PID until cleanup holds the lock, preventing PID reuse.
  os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOWAIT)
  fcntl.flock(lock, fcntl.LOCK_EX)
  stop_group(child.pid, grace=False)
  code = child.wait()
  os.unlink(pid_path)
  sys.exit(code if code >= 0 else 128 - code)
  """

  def wrap(command, directory), do: ["python3", "-c", @supervisor, "run", directory | command]

  def validate_runtime(executable, container) do
    case System.cmd(
           executable,
           ["exec", container, "python3", "-c", "import fcntl, os; assert hasattr(os, 'waitid')"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, _} ->
        {:error,
         "DockerWorker requires Python 3 process supervision in its prepared image: #{output}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def stop(executable, container, directory) do
    case System.cmd(
           executable,
           ["exec", container, "python3", "-c", @supervisor, "stop", directory],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        # A removed/stopped container has no remaining command processes. Other
        # Docker failures remain errors and keep the invocation owned for retry.
        case System.cmd(executable, ["inspect", "--format", "{{.State.Running}}", container],
               stderr_to_stdout: true
             ) do
          {"false\n", 0} ->
            :ok

          {missing, 1} ->
            if String.contains?(missing, "No such object:") or
                 String.contains?(missing, "No such container:"),
               do: :ok,
               else: {:error, %{exit_code: code, output: output}}

          _ ->
            {:error, %{exit_code: code, output: output}}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def run(opts, function) do
    owner = self()
    result_ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        owner_ref = Process.monitor(owner)
        job_id = Keyword.fetch!(opts, :job_id)
        {:ok, _} = Registry.register(@registry, job_id, Keyword.get(opts, :agent_id))

        if Process.alive?(owner) do
          result = function.(Keyword.put(opts, :docker_owner_monitor, owner_ref))
          send(owner, {result_ref, result})
        end
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, "DockerWorker command supervisor exited: #{inspect(reason)}"}
    end
  end

  def terminate_job(job_id) do
    terminate_agents(job_id, :all)
  end

  def terminate_agents(job_id, agent_ids) do
    runners =
      if Process.whereis(@registry), do: Registry.lookup(@registry, job_id), else: []

    runners =
      Enum.filter(runners, fn {_pid, agent_id} -> agent_ids == :all or agent_id in agent_ids end)

    monitors =
      Enum.map(runners, fn {pid, _} ->
        ref = Process.monitor(pid)
        send(pid, :terminate_docker_command)
        {pid, ref}
      end)

    deadline = System.monotonic_time(:millisecond) + 10_000

    Enum.reduce(monitors, :ok, fn {pid, ref}, result ->
      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> result
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          Process.demonitor(ref, [:flush])
          {:error, :docker_command_cleanup_timeout}
      end
    end)
  end
end
