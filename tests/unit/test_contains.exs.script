defmodule TestContains do
  def run do
    try do
      String.contains?(%{error: "test"}, "was not found")
      IO.puts("Success")
    rescue
      e in FunctionClauseError -> IO.puts("FunctionClauseError")
      e -> IO.puts("Other error: #{inspect(e)}")
    end
  end
end
TestContains.run()
