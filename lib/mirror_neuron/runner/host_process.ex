defmodule MirrorNeuron.Runner.HostProcess do
  @moduledoc false

  @term_grace_ms 500
  @kill_grace_ms 100

  def isolate(executable, args) when is_binary(executable) and is_list(args) do
    case System.find_executable("setsid") do
      nil -> {executable, args, false}
      setsid -> {setsid, [executable | args], true}
    end
  end

  def terminate(port, process_group?) when is_port(port) do
    case port_os_pid(port) do
      pid when is_integer(pid) and pid > 0 ->
        signal(pid, "TERM", process_group?)

        unless await_exit(port, @term_grace_ms) do
          signal(pid, "KILL", process_group?)
          _ = await_exit(port, @kill_grace_ms)
        end

      _ ->
        :ok
    end

    close(port)
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp signal(pid, signal, process_group?) do
    target = if process_group?, do: -pid, else: pid

    case System.find_executable("kill") do
      executable when is_binary(executable) ->
        _ =
          System.cmd(
            executable,
            ["-#{signal}", "--", Integer.to_string(target)],
            stderr_to_stdout: true
          )

      nil ->
        signal_with_python(target, signal, process_group?)
    end

    :ok
  rescue
    ErlangError -> :ok
  end

  defp signal_with_python(target, signal, process_group?) do
    with executable when is_binary(executable) <- System.find_executable("python3") do
      script =
        "import os,signal,sys; target=int(sys.argv[1]); " <>
          "selected=getattr(signal,'SIG'+sys.argv[2]); " <>
          "os.killpg(abs(target),selected) if sys.argv[3]=='group' " <>
          "else os.kill(target,selected)"

      case run_python_signal(executable, script, target, signal, process_group?) do
        {_output, 0} ->
          :ok

        {_output, _status} when process_group? ->
          _ = run_python_signal(executable, script, abs(target), signal, false)
          :ok

        {_output, _status} ->
          :ok
      end
    end
  end

  defp run_python_signal(executable, script, target, signal, process_group?) do
    System.cmd(
      executable,
      [
        "-c",
        script,
        Integer.to_string(target),
        signal,
        if(process_group?, do: "group", else: "process")
      ],
      stderr_to_stdout: true
    )
  end

  defp await_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, _exit_code}} -> true
    after
      timeout_ms -> not port_open?(port)
    end
  end

  defp port_open?(port) do
    not is_nil(Port.info(port))
  rescue
    ArgumentError -> false
  end

  defp close(port) do
    if port_open?(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
