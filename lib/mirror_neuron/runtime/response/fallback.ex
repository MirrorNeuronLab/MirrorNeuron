defmodule MirrorNeuron.Runtime.JobResponse.Fallback do
  @moduledoc "Bounded deterministic status answers with sanitized context citations."

  alias MirrorNeuron.Runtime
  alias MirrorNeuron.Runtime.JobResponse.Validation

  @max_answer_bytes 64 * 1_024

  def fallback(attrs, definition, service_state, warning_code) do
    context = attrs["context"] || %{}
    profile = if is_map(context["profile"]), do: context["profile"], else: %{}
    latest = if is_map(context["latest_run"]), do: context["latest_run"], else: nil

    name =
      safe_string(
        profile["name"] || definition["job_name"] || definition["blueprint_id"] || "This job",
        512,
        "This job"
      )

    job_state = safe_string(context["state"], 100, "unknown")

    parts = ["#{name} is currently #{String.replace(to_string(job_state), "_", " ")}."]

    parts =
      if is_binary(profile["mission"]) and String.trim(profile["mission"]) != "" do
        parts ++ ["Its declared purpose is: #{String.slice(profile["mission"], 0, 1_200)}"]
      else
        parts
      end

    parts =
      if is_map(latest) do
        parts ++
          [
            "The latest run (#{safe_string(latest["run_id"], 200, "latest")}) is #{safe_string(latest["status"], 100, "unknown")}."
          ]
      else
        parts ++
          ["It has not started a run yet, so there is no run progress or result to report."]
      end

    answer =
      Enum.join(
        parts ++
          [
            "This is a grounded status summary; the semantic answer service was unavailable, so no additional conclusion was inferred."
          ],
        "\n\n"
      )

    response = %{
      "schema_version" => "mn.mcp.job_answer.v1",
      "answer" => String.slice(answer, 0, 12_000),
      "conversation_id" => attrs["conversation_id"] || uuid(),
      "request_id" => attrs["request_id"],
      "job_id" => definition["job_id"],
      "state" => %{
        "job" => job_state,
        "latest_run" => fallback_latest_state(latest)
      },
      "citations" => fallback_citations(context["evidence"]),
      "warnings" => [
        "A deterministic answer was returned because the response service was unavailable.",
        warning_code
      ],
      "service" => %{"state" => service_state},
      "model" => %{"used" => false, "fallback" => true},
      "conversation_persisted" => false
    }

    response =
      if Validation.bounded_agent?(definition) do
        Map.merge(response, %{
          "schema_version" => "mn.mcp.job_answer.v3",
          "turn" => %{
            "turn_id" => uuid(),
            "state" => "completed",
            "updated_at" => Runtime.timestamp()
          },
          "effects" => []
        })
      else
        response
      end

    fit_fallback(response)
  end

  defp fit_fallback(answer) do
    cond do
      encoded_answer_size(answer) <= @max_answer_bytes ->
        answer

      answer["citations"] != [] ->
        answer
        |> Map.update!("citations", &Enum.drop(&1, -1))
        |> fit_fallback()

      get_in(answer, ["state", "latest_run"]) != nil ->
        answer
        |> put_in(["state", "latest_run"], nil)
        |> fit_fallback()

      String.length(answer["answer"] || "") > 4_000 ->
        answer
        |> Map.update!("answer", &String.slice(&1, 0, 4_000))
        |> fit_fallback()

      length(answer["warnings"] || []) > 1 ->
        answer
        |> Map.put("warnings", ["The deterministic response was truncated to the answer limit."])
        |> fit_fallback()

      true ->
        Map.update!(answer, "answer", &String.slice(&1, 0, 1_000))
    end
  end

  defp encoded_answer_size(answer) do
    answer |> Jason.encode!() |> byte_size()
  rescue
    _ -> @max_answer_bytes + 1
  end

  defp fallback_citations(evidence) when is_list(evidence) do
    evidence
    |> Enum.filter(&is_map/1)
    |> Enum.take(20)
    |> Enum.map(fn item ->
      %{
        "kind" => safe_string(item["kind"], 100, "job_context"),
        "record_id" => safe_string(item["record_id"], 200, "evidence"),
        "summary" => safe_string(item["summary"], 800),
        "status" => safe_string(item["status"], 100)
      }
    end)
  end

  defp fallback_citations(_evidence), do: []

  defp fallback_latest_state(nil), do: nil

  defp fallback_latest_state(latest) when is_map(latest) do
    ~w(run_id status started_at updated_at completed_at finished_at)
    |> Enum.reduce(%{}, fn key, result ->
      case safe_string(latest[key], 256) do
        "" -> result
        value -> Map.put(result, key, value)
      end
    end)
  end

  defp safe_string(value, limit, fallback \\ "")

  defp safe_string(value, limit, _fallback) when is_binary(value),
    do: String.slice(value, 0, limit)

  defp safe_string(value, _limit, _fallback)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: to_string(value)

  defp safe_string(_value, _limit, fallback), do: fallback

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) + 0x4000
    d = Bitwise.band(d, 0x3FFF) + 0x8000

    Enum.join(
      [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)],
      "-"
    )
  end

  defp hex(value, length), do: value |> Integer.to_string(16) |> String.pad_leading(length, "0")
end
