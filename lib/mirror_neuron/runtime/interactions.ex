defmodule MirrorNeuron.Runtime.Interactions do
  @moduledoc "Durable, revision-checked human decisions. Effects are acknowledged separately."
  alias MirrorNeuron.Persistence.InteractionStore
  @kinds ~w(approval choice input form notice review display session)
  @widgets ~w(plan task activity summary tool confirmation sources artifact checkpoint queue context form choice notice)

  def command(%{"op" => "snapshot"}), do: InteractionStore.snapshot()
  def command(%{"op" => "get", "id" => id}), do: InteractionStore.get(id)
  def command(%{"op" => "create", "record" => record}) do
    with :ok <- validate(record) do
      now = System.system_time(:millisecond)
      record = Map.merge(Map.take(record, ~w(id scope kind presentation options fields expires_at blocking metadata evidence)), %{"schema" => "mn.interaction.v1", "revision" => 1,
        "state" => "pending", "effect" => "not_started", "created_at" => now, "updated_at" => now,
        "owner" => to_string(MirrorNeuron.Cluster.NodeAdapter.self())})
      InteractionStore.create(record)
    end
  end
  def command(%{"op" => op, "id" => id} = command) when op in ~w(respond acknowledge cancel effect update) do
    with {:ok, record} <- InteractionStore.get(id),
         :ok <- validate_response(op, record, command) do
      InteractionStore.transition(op, record, command)
    end
  end
  def command(_), do: {:error, "invalid_command"}

  def validate(record) when is_map(record) do
    options = Map.get(record, "options", [])
    fields = Map.get(record, "fields", [])
    cond do
      byte_size(Jason.encode!(record)) > 32_768 -> {:error, "payload_too_large"}
      not identifier?(record["id"]) -> {:error, "invalid_identity"}
      record["kind"] not in @kinds -> {:error, "invalid_kind"}
      get_in(record, ["presentation", "widget"]) not in @widgets -> {:error, "invalid_widget"}
      not is_map(record["scope"]) -> {:error, "invalid_scope"}
      not identifier?(record["scope"]["job_id"] || record["scope"]["session_id"]) -> {:error, "invalid_scope"}
      record["scope"]["job_id"] != nil and record["scope"]["session_id"] != nil -> {:error, "invalid_scope"}
      not valid_presentation?(record["presentation"]) -> {:error, "invalid_presentation"}
      record["scope"]["job_id"] != nil and not identifier?(record["scope"]["execution_id"]) -> {:error, "execution_identity_required"}
      not is_list(options) or length(options) > 12 -> {:error, "invalid_options"}
      not Enum.all?(options, &(is_map(&1) and identifier?(&1["id"]) and bounded?(&1["label"], 160) and &1["action"] in ~w(approve reject revise choose))) -> {:error, "invalid_options"}
      length(Enum.uniq_by(options, & &1["id"])) != length(options) -> {:error, "invalid_options"}
      not is_list(fields) or length(fields) > 20 -> {:error, "invalid_fields"}
      not Enum.all?(fields, &(is_map(&1) and identifier?(&1["id"]) and &1["type"] in ~w(text number boolean select))) -> {:error, "invalid_fields"}
      length(Enum.uniq_by(fields, & &1["id"])) != length(fields) -> {:error, "invalid_fields"}
      record["expires_at"] != nil and not is_integer(record["expires_at"]) -> {:error, "invalid_deadline"}
      true -> :ok
    end
  end
  def validate(_), do: {:error, "invalid_record"}

  def validate_response(op, record, command) do
    answer = Map.get(command, "answer", %{})
    options = Map.get(record, "options", [])
    cond do
      not identifier?(command["command_id"]) -> {:error, "invalid_command_id"}
      not is_integer(command["expected_revision"]) -> {:error, "invalid_revision"}
      not is_map(answer) or byte_size(Jason.encode!(answer)) > 16_384 -> {:error, "invalid_answer"}
      op == "respond" and record["kind"] in ~w(display session notice) -> {:error, "invalid_response_kind"}
      op == "respond" and options != [] and not Enum.any?(options, &(&1["id"] == answer["option_id"])) -> {:error, "invalid_option"}
      op == "respond" and record["kind"] == "input" and not nonempty?(answer["text"]) -> {:error, "answer_required"}
      op == "respond" and not valid_fields?(Map.get(record, "fields", []), Map.get(answer, "values", %{})) -> {:error, "invalid_fields"}
      op == "acknowledge" and record["kind"] != "notice" -> {:error, "invalid_acknowledgement"}
      op == "effect" and command["effect"] not in ~w(running applied failed) -> {:error, "invalid_effect"}
      op == "update" and (not valid_presentation?(command["presentation"])) -> {:error, "invalid_widget"}
      Map.keys(answer) -- ~w(option_id text values) != [] -> {:error, "invalid_answer"}
      answer["text"] != nil and not bounded?(answer["text"], 8000) -> {:error, "invalid_answer"}
      true -> :ok
    end
  end

  defp valid_fields?(fields, values) when is_map(values) do
    Enum.all?(Map.keys(values), fn key -> Enum.any?(fields, &(&1["id"] == key)) end) and
      Enum.all?(fields, fn field ->
        value = values[field["id"]]
        if is_nil(value), do: field["required"] != true, else: valid_field?(field, value) and (field["required"] != true or field["type"] != "text" or nonempty?(value))
      end)
  end
  defp valid_fields?(_, _), do: false
  defp valid_field?(%{"type" => "text"}, value), do: is_binary(value) and byte_size(value) <= 8_000
  defp valid_field?(%{"type" => "number"}, value), do: is_number(value)
  defp valid_field?(%{"type" => "boolean"}, value), do: is_boolean(value)
  defp valid_field?(%{"type" => "select"} = field, value), do: value in Map.get(field, "options", [])
  defp valid_field?(_, _), do: false
  defp valid_presentation?(value) when is_map(value) do
    value["widget"] in @widgets and bounded?(value["title"], 240) and
      (is_nil(value["text"]) or bounded?(value["text"], 8000)) and
      bounded_list?(Map.get(value, "items", []), 40, &bounded?(&1, 500)) and
      bounded_list?(Map.get(value, "sources", []), 20, fn source ->
        is_map(source) and bounded?(source["title"], 240) and bounded?(source["url"], 2048) and
          Regex.match?(~r/^https?:\/\//, source["url"])
      end)
  end
  defp valid_presentation?(_), do: false
  defp bounded_list?(value, count, check), do: is_list(value) and length(value) <= count and Enum.all?(value, check)
  defp bounded?(value, limit), do: is_binary(value) and String.length(value) <= limit
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 8_000
  defp identifier?(value), do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}$/, value)
end
