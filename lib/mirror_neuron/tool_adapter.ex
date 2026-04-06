defmodule MirrorNeuron.ToolAdapter do
  def invoke("template", %{"template" => template}, payload) do
    input =
      payload
      |> extract_input()
      |> to_string()

    {:ok, String.replace(template, "{{input}}", input)}
  end

  def invoke("echo", _config, payload), do: {:ok, payload}
  def invoke(tool_name, _config, _payload), do: {:error, "unsupported tool #{inspect(tool_name)}"}

  defp extract_input(%{"text" => text}), do: text
  defp extract_input(%{text: text}), do: text
  defp extract_input(payload), do: inspect(payload)
end
