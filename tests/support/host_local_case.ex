defmodule MirrorNeuron.HostLocalCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MirrorNeuron.HostLocalCase
    end
  end

  setup_all do
    if is_nil(Process.whereis(MirrorNeuron.Runner.HostProcessRegistry)) do
      start_supervised!(
        {Registry, keys: :duplicate, name: MirrorNeuron.Runner.HostProcessRegistry}
      )
    end

    :ok
  end

  def create_test_wheel(path) do
    files = [
      {~c"mn_test_pkg/__init__.py", "VALUE = 'from-wheel'\n"},
      {~c"mn_test_pkg-0.1.dist-info/METADATA",
       "Metadata-Version: 2.1\nName: mn-test-pkg\nVersion: 0.1\n"},
      {~c"mn_test_pkg-0.1.dist-info/WHEEL",
       "Wheel-Version: 1.0\nGenerator: mirror-neuron-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n"},
      {~c"mn_test_pkg-0.1.dist-info/RECORD",
       "mn_test_pkg/__init__.py,,\nmn_test_pkg-0.1.dist-info/METADATA,,\nmn_test_pkg-0.1.dist-info/WHEEL,,\nmn_test_pkg-0.1.dist-info/RECORD,,\n"}
    ]

    {:ok, _path} = :zip.create(String.to_charlist(path), files)
  end

  def wait_until(predicate, attempts \\ 100)

  def wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      true
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  def wait_until(_predicate, 0), do: false

  def os_process_alive?(pid) do
    case System.find_executable("kill") do
      nil ->
        false

      executable ->
        {_output, status} =
          System.cmd(executable, ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

        status == 0
    end
  end

  def python_process_alive?(python, pid) do
    {_output, status} =
      System.cmd(
        python,
        ["-c", "import os,sys; os.kill(int(sys.argv[1]), 0)", Integer.to_string(pid)],
        stderr_to_stdout: true
      )

    status == 0
  end

  def terminate_recorded_process(pid_path) do
    with true <- File.exists?(pid_path),
         {pid, ""} <- pid_path |> File.read!() |> String.trim() |> Integer.parse(),
         executable when is_binary(executable) <- System.find_executable("kill") do
      _ = System.cmd(executable, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  def restore_env(name, nil), do: System.delete_env(name)
  def restore_env(name, value), do: System.put_env(name, value)
end
