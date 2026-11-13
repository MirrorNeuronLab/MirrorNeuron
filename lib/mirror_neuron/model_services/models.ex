defmodule MirrorNeuron.ModelServices.Models do
  @moduledoc "Normalizes model purpose defaults and explicit backup preparation requests."

  @default_llm_model "nemotron-3.5-bolt-e4b:q4_k_m"
  @default_context_engine_model "default"
  @default_knowledge_rag_model "huggingface.co/zenmagnets/Nemotron-3-Embed-1B-Q4_K_M-GGUF:Q4_K_M"

  def normalize_runtime_model_prepare_attrs(%{"purpose" => "job_backup"} = attrs) do
    if attrs["action"] in ["export_hostlocal_wheels", "inspect_hostlocal_python"] or
         attrs["ensure_hostlocal_python_environment"] == true do
      {:ok, Map.drop(attrs, ["model", "runtime_model"])}
    else
      {:error, "unsupported job backup Python request"}
    end
  end

  def normalize_runtime_model_prepare_attrs(attrs) when is_map(attrs) do
    case runtime_model_for_prepare_purpose(prepare_model_ref(attrs), prepare_model_purpose(attrs)) do
      {:ok, model} ->
        {:ok,
         attrs
         |> Map.put("model", model)
         |> Map.put("runtime_model", model)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_model_ref(attrs) do
    attrs
    |> first_present(["model", :model, "runtime_model", :runtime_model, "id", :id])
    |> to_string()
    |> String.trim()
  end

  defp prepare_model_purpose(attrs) do
    attrs
    |> first_present(["purpose", :purpose, "model_purpose", :model_purpose])
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp runtime_model_for_prepare_purpose("", purpose) do
    case purpose do
      "" -> {:ok, @default_llm_model}
      "llm" -> {:ok, @default_llm_model}
      "runtime" -> {:ok, @default_llm_model}
      "runtime_llm" -> {:ok, @default_llm_model}
      "default" -> {:ok, @default_llm_model}
      "context" -> {:ok, @default_context_engine_model}
      "context_engine" -> {:ok, @default_context_engine_model}
      "context_model" -> {:ok, @default_context_engine_model}
      "context_engine_model" -> {:ok, @default_context_engine_model}
      "knowledge_rag" -> {:ok, @default_knowledge_rag_model}
      "rag" -> {:ok, @default_knowledge_rag_model}
      "embedding" -> {:ok, @default_knowledge_rag_model}
      "knowledge_rag_embedding" -> {:ok, @default_knowledge_rag_model}
      other -> {:error, "unsupported runtime model prepare purpose: #{other}"}
    end
  end

  defp runtime_model_for_prepare_purpose("default", _purpose), do: {:ok, @default_llm_model}

  defp runtime_model_for_prepare_purpose(model, _purpose), do: {:ok, model}

  defp first_present(attrs, keys) do
    Enum.find_value(keys, "", fn key ->
      case Map.get(attrs, key) do
        nil -> nil
        value -> value
      end
    end)
  end
end
