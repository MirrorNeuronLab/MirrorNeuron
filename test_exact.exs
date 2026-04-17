defmodule TestExact do
  def run do
    job_id = "divisibility_monitor_v1-1776392018601-2e6d048aceaf"
    result = {:error, "job #{job_id} is not running in the connected cluster"}
    case result do
      {:error, "job " <> _ = reason} -> IO.puts("MATCHED: #{reason}")
      other -> IO.puts("OTHER: #{inspect(other)}")
    end
  end
end
TestExact.run()
