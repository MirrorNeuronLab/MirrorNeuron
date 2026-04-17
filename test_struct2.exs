defmodule TestStruct2 do
  def run do
    try do
      String.contains?(DateTime.utc_now(), "was not found")
      IO.puts("Success")
    rescue
      e -> IO.puts("Error: #{inspect(e)}")
    end
  end
end
TestStruct2.run()
