defmodule TestBind do
  def run do
    result = {:error, "job test is not running"}
    case result do
      {:error, "job " <> _ = reason} ->
        IO.puts("reason is: #{reason}")
    end
  end
end
TestBind.run()
