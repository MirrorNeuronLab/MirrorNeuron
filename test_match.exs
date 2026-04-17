defmodule TestMatch do
  def run do
    result = {:error, "job drug_discovery_loop-1776388976672-1c50c86dc919 is not running in the connected cluster"}
    case result do
      {:error, "job " <> _ = reason} -> IO.puts("MATCH: #{reason}")
      other -> IO.puts("OTHER: #{inspect(other)}")
    end
  end
end
TestMatch.run()
