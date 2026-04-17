defmodule TestCancelFlow do
  def run do
    job_id = "drug_discovery_loop-1776388976672-1c50c86dc919"
    result = {:error, "job #{job_id} is not running in the connected cluster"}
    
    case result do
      {:error, "job " <> _ = reason} ->
        IO.puts("Matched! Calling force cancel with #{reason}")
        
      other ->
        IO.puts("No match! #{inspect(other)}")
    end
  end
end
TestCancelFlow.run()
