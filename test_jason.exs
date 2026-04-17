defmodule TestJason do
  def run do
    case Jason.decode("invalid") do
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
      {:ok, _} -> IO.puts("Ok")
    end
  end
end
TestJason.run()
