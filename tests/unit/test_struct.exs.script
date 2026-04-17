defmodule TestStruct do
  def run do
    reason = %Jason.DecodeError{position: 0, token: nil, data: ""}
    String.contains?(reason, "was not found")
  end
end
TestStruct.run()
