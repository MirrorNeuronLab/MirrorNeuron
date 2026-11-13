defmodule MirrorNeuron.Runtime.SchedulePolicy do
  @moduledoc "Schedule normalization, due occurrences, catch-up and event matching."

  alias MirrorNeuron.Scheduler.Schedules.Cron

  @default_grace_ms 60_000
  @default_catchup_limit 10
  @supported_kinds ["periodic", "delayed", "event", "resource_wait"]
  @supported_missed_policies ["skip", "catchup_one", "catchup_all"]
  @supported_end_actions ["cancel", "pause", "none"]

  def normalize(schedule, manifest \\ nil, opts \\ [])

  def normalize(nil, manifest, opts), do: normalize(%{}, manifest, opts)

  def normalize(schedule, manifest, opts) when is_map(schedule) do
    raw = stringify(schedule)
    kind = infer_kind(raw)
    enabled = bool(Map.get(raw, "enabled", true))
    now = Keyword.get(opts, :now, now())

    normalized =
      %{
        "kind" => kind,
        "enabled" => enabled,
        "status" => if(enabled, do: "active", else: "paused"),
        "name" =>
          Map.get(raw, "name") || (manifest && Map.get(manifest_map(manifest), "job_name")),
        "crons" => normalize_crons(raw),
        "timezone" => normalize_timezone(Map.get(raw, "timezone", Map.get(raw, "time_zone"))),
        "run_at" => normalize_run_at(raw, now),
        "prohibit_overlap" => bool(Map.get(raw, "prohibit_overlap", true)),
        "missed_policy" => normalize_missed_policy(Map.get(raw, "missed_policy")),
        "catchup_limit" => positive_int(Map.get(raw, "catchup_limit"), @default_catchup_limit),
        "missed_grace_ms" => positive_int(Map.get(raw, "missed_grace_ms"), @default_grace_ms),
        "window" => normalize_window(Map.get(raw, "window", %{})),
        "trigger" => normalize_trigger(raw),
        "retry_interval_ms" => resource_wait_interval(kind, raw),
        "max_wait_ms" => resource_wait_max_wait(kind, raw),
        "parameterized" => normalize_parameterized(Map.get(raw, "parameterized", %{})),
        "metadata" => Map.get(raw, "metadata", %{})
      }
      |> drop_empty()
      |> apply_service_lifecycle(manifest)

    case validate(normalized) do
      :ok -> {:ok, put_next_run(normalized, now)}
      {:error, errors} -> {:error, errors}
    end
  end

  def normalize(_other, _manifest, _opts), do: {:error, ["schedule must be an object"]}

  def validate(schedule) when is_map(schedule) do
    errors =
      []
      |> add_error(
        Map.get(schedule, "kind") not in @supported_kinds,
        "schedule.kind must be periodic, delayed, event, or resource_wait"
      )
      |> validate_kind(schedule)
      |> validate_window(schedule)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def next_run_at(schedule, after_iso_or_dt \\ now())

  def next_run_at(%{"kind" => "periodic"} = schedule, after_iso_or_dt) do
    after_dt = parse_datetime(after_iso_or_dt) || now()

    schedule
    |> Map.get("crons", [])
    |> Enum.flat_map(fn cron ->
      case Cron.next_cron_after(cron, after_dt) do
        {:ok, datetime} -> [datetime]
        _ -> []
      end
    end)
    |> Enum.sort(fn left, right -> DateTime.compare(left, right) != :gt end)
    |> List.first()
    |> iso_or_nil()
  end

  def next_run_at(%{"kind" => "delayed", "run_at" => run_at}, _after_iso_or_dt), do: run_at

  def next_run_at(_schedule, _after_iso_or_dt), do: nil

  def due_instances(schedule, now_iso_or_dt \\ now()) do
    now_dt = parse_datetime(now_iso_or_dt) || now()
    next_dt = parse_datetime(Map.get(schedule, "next_run_at"))

    cond do
      not Map.get(schedule, "enabled", true) ->
        []

      Map.get(schedule, "status") in ["paused", "completed", "deleted"] ->
        []

      is_nil(next_dt) or DateTime.compare(next_dt, now_dt) == :gt ->
        []

      Map.get(schedule, "kind") == "periodic" ->
        periodic_due_instances(schedule, next_dt, now_dt)

      Map.get(schedule, "kind") == "delayed" ->
        [%{"scheduled_for" => DateTime.to_iso8601(next_dt), "reason" => "delayed"}]

      Map.get(schedule, "kind") == "resource_wait" ->
        [%{"scheduled_for" => DateTime.to_iso8601(next_dt), "reason" => "resource_wait"}]

      true ->
        []
    end
  end

  def missed?(schedule, now_iso_or_dt \\ now()) do
    now_dt = parse_datetime(now_iso_or_dt) || now()
    next_dt = parse_datetime(Map.get(schedule, "next_run_at"))

    is_struct(next_dt, DateTime) and
      Map.get(schedule, "kind") == "periodic" and
      Map.get(schedule, "missed_policy", "skip") == "skip" and
      DateTime.diff(now_dt, next_dt, :millisecond) >
        Map.get(schedule, "missed_grace_ms", @default_grace_ms)
  end

  def event_matches?(schedule, event) do
    trigger = Map.get(schedule, "trigger", %{})
    event = stringify(event || %{})
    payload = Map.get(event, "payload", %{})
    filters = Map.get(trigger, "filters", %{})

    Map.get(schedule, "kind") == "event" and
      Map.get(schedule, "enabled", true) and
      Map.get(schedule, "status", "active") == "active" and
      event_type_matches(Map.get(trigger, "event_type"), Map.get(event, "event_type")) and
      Enum.all?(filters, fn {path, expected} ->
        actual =
          case to_string(path) do
            "event_type" -> Map.get(event, "event_type")
            "source" -> Map.get(event, "source")
            other -> get_path(payload, other)
          end

        filter_value_matches?(actual, expected)
      end)
  end

  def dispatch_payload(schedule, event \\ nil) do
    %{
      "schedule_id" => Map.get(schedule, "schedule_id"),
      "schedule_kind" => Map.get(schedule, "kind"),
      "schedule_name" => Map.get(schedule, "name"),
      "trigger_event" => event
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end

  def now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)

  defp put_next_run(%{"kind" => "event"} = schedule, _now),
    do: Map.put_new(schedule, "next_run_at", nil)

  defp put_next_run(%{"kind" => "delayed"} = schedule, _now),
    do: Map.put(schedule, "next_run_at", Map.get(schedule, "run_at"))

  defp put_next_run(%{"kind" => "resource_wait"} = schedule, now),
    do:
      Map.put(
        schedule,
        "next_run_at",
        Map.get(schedule, "next_run_at") || DateTime.to_iso8601(now)
      )

  defp put_next_run(%{"kind" => "periodic"} = schedule, now) do
    Map.put(
      schedule,
      "next_run_at",
      Map.get(schedule, "next_run_at") || next_run_at(schedule, now)
    )
  end

  defp infer_kind(%{"kind" => kind}) when is_binary(kind), do: String.downcase(kind)

  defp infer_kind(%{"auto_schedule" => true}), do: "resource_wait"

  defp infer_kind(%{"event_type" => _}), do: "event"

  defp infer_kind(%{"trigger" => _}), do: "event"

  defp infer_kind(%{"run_at" => _}), do: "delayed"

  defp infer_kind(%{"delay_ms" => _}), do: "delayed"

  defp infer_kind(_raw), do: "periodic"

  defp normalize_crons(raw) do
    cond do
      is_list(Map.get(raw, "crons")) ->
        raw["crons"]
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      is_binary(Map.get(raw, "cron")) ->
        [String.trim(raw["cron"])]

      true ->
        []
    end
  end

  defp normalize_timezone(value) when is_binary(value) and value != "", do: value

  defp normalize_timezone(_value), do: "UTC"

  defp normalize_run_at(raw, now) do
    cond do
      is_binary(Map.get(raw, "run_at")) ->
        raw["run_at"]

      is_integer(Map.get(raw, "delay_ms")) ->
        now |> DateTime.add(max(raw["delay_ms"], 0), :millisecond) |> DateTime.to_iso8601()

      true ->
        nil
    end
  end

  defp normalize_missed_policy(value) when is_binary(value) do
    normalized = String.downcase(value)
    if normalized in @supported_missed_policies, do: normalized, else: "skip"
  end

  defp normalize_missed_policy(_value), do: "skip"

  defp normalize_window(window) when is_map(window) do
    window = stringify(window)
    duration = positive_int(Map.get(window, "duration_ms"), nil)
    end_action = Map.get(window, "end_action", "cancel") |> to_string() |> String.downcase()

    %{
      "duration_ms" => duration,
      "end_action" => if(end_action in @supported_end_actions, do: end_action, else: "cancel")
    }
    |> drop_empty()
  end

  defp normalize_window(_window), do: %{}

  defp normalize_trigger(%{"trigger" => trigger}) when is_map(trigger) do
    normalize_trigger(trigger)
  end

  defp normalize_trigger(raw) do
    %{
      "event_type" => Map.get(raw, "event_type") || Map.get(raw, "type"),
      "filters" => stringify(Map.get(raw, "filters", %{})),
      "payload" => Map.get(raw, "payload", "optional"),
      "meta_required" => Map.get(raw, "meta_required", []),
      "meta_optional" => Map.get(raw, "meta_optional", [])
    }
    |> drop_empty()
  end

  defp normalize_parameterized(value) when is_map(value), do: stringify(value)

  defp normalize_parameterized(_value), do: %{}

  defp validate_kind(errors, %{"kind" => "periodic"} = schedule) do
    crons = Map.get(schedule, "crons", [])

    errors
    |> add_error(crons == [], "periodic schedules require cron or crons")
    |> add_errors(invalid_cron_errors(crons))
    |> add_error(
      Map.get(schedule, "missed_policy") not in @supported_missed_policies,
      "schedule.missed_policy must be skip, catchup_one, or catchup_all"
    )
  end

  defp validate_kind(errors, %{"kind" => "delayed"} = schedule) do
    errors
    |> add_error(
      is_nil(parse_datetime(Map.get(schedule, "run_at"))),
      "delayed schedules require a valid run_at or delay_ms"
    )
  end

  defp validate_kind(errors, %{"kind" => "event"} = schedule) do
    event_type = get_in(schedule, ["trigger", "event_type"])

    errors
    |> add_error(not valid_name?(event_type), "event schedules require trigger.event_type")
  end

  defp validate_kind(errors, %{"kind" => "resource_wait"} = schedule) do
    add_error(
      errors,
      Map.get(schedule, "retry_interval_ms", 30_000) <= 0,
      "resource_wait schedules require retry_interval_ms greater than zero"
    )
  end

  defp validate_kind(errors, _schedule), do: errors

  defp validate_window(errors, schedule) do
    end_action = get_in(schedule, ["window", "end_action"])

    add_error(
      errors,
      is_binary(end_action) and end_action not in @supported_end_actions,
      "schedule.window.end_action must be cancel, pause, or none"
    )
  end

  defp apply_service_lifecycle(schedule, manifest) do
    if manifest_map(manifest)["type"] == "service" do
      schedule
      |> Map.put("target_type", "service")
      |> Map.update("window", %{}, fn
        %{"duration_ms" => duration} = window when is_integer(duration) and duration > 0 ->
          Map.put(window, "end_action", "pause")

        window ->
          window
      end)
    else
      schedule
    end
  end

  defp invalid_cron_errors(crons) do
    crons
    |> Enum.reject(fn cron -> match?({:ok, _}, Cron.parse_cron(cron)) end)
    |> Enum.map(&"invalid cron expression #{inspect(&1)}")
  end

  defp periodic_due_instances(schedule, next_dt, now_dt) do
    missed_policy = Map.get(schedule, "missed_policy", "skip")
    grace_ms = Map.get(schedule, "missed_grace_ms", @default_grace_ms)
    late_ms = DateTime.diff(now_dt, next_dt, :millisecond)

    cond do
      missed_policy == "skip" and late_ms > grace_ms ->
        []

      missed_policy == "catchup_all" ->
        schedule
        |> catchup_datetimes(next_dt, now_dt)
        |> Enum.map(&%{"scheduled_for" => DateTime.to_iso8601(&1), "reason" => "periodic"})

      true ->
        [%{"scheduled_for" => DateTime.to_iso8601(next_dt), "reason" => "periodic"}]
    end
  end

  defp catchup_datetimes(schedule, first_dt, now_dt) do
    limit = Map.get(schedule, "catchup_limit", @default_catchup_limit)

    Enum.reduce_while(1..limit, {[], first_dt}, fn _index, {acc, dt} ->
      if DateTime.compare(dt, now_dt) == :gt do
        {:halt, {acc, dt}}
      else
        next_iso = next_run_at(schedule, DateTime.add(dt, 60, :second))
        next_dt = parse_datetime(next_iso)
        {:cont, {[dt | acc], next_dt || DateTime.add(now_dt, 1, :second)}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp parse_datetime(%DateTime{} = datetime), do: DateTime.truncate(datetime, :millisecond)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :millisecond)
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp iso_or_nil(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp iso_or_nil(_value), do: nil

  defp event_type_matches(expected, actual) when is_list(expected), do: actual in expected

  defp event_type_matches(expected, actual),
    do: to_string(expected || "") == to_string(actual || "")

  defp filter_value_matches?(_actual, nil), do: true

  defp filter_value_matches?(actual, expected) when is_list(expected), do: actual in expected

  defp filter_value_matches?(actual, %{"prefix" => prefix}) when is_binary(actual),
    do: String.starts_with?(actual, to_string(prefix))

  defp filter_value_matches?(actual, %{"contains" => needle}) when is_binary(actual),
    do: String.contains?(actual, to_string(needle))

  defp filter_value_matches?(actual, expected),
    do: to_string(actual || "") == to_string(expected || "")

  defp get_path(map, path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce(stringify(map), fn key, acc ->
      if is_map(acc), do: Map.get(acc, key), else: nil
    end)
  end

  defp valid_name?(value), do: is_binary(value) and value =~ ~r/^[a-zA-Z0-9_.:-]{1,160}$/

  defp bool(value) when is_boolean(value), do: value

  defp bool(value) when is_binary(value), do: String.downcase(value) in ["1", "true", "yes", "on"]

  defp bool(_value), do: false

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

  defp resource_wait_interval("resource_wait", raw),
    do: positive_int(Map.get(raw, "retry_interval_ms"), 30_000)

  defp resource_wait_interval(_kind, _raw), do: nil

  defp resource_wait_max_wait("resource_wait", raw),
    do: positive_int(Map.get(raw, "max_wait_ms"), nil)

  defp resource_wait_max_wait(_kind, _raw), do: nil

  defp manifest_map(%MirrorNeuron.Manifest{} = manifest),
    do: MirrorNeuron.Manifest.to_map(manifest)

  defp manifest_map(map) when is_map(map), do: stringify(map)

  defp manifest_map(_other), do: %{}

  defp stringify(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      {key, stringify(value)}
    end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(value), do: value

  defp drop_empty(map) do
    Enum.reject(map, fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp add_error(errors, true, message), do: [message | errors]

  defp add_error(errors, _false, _message), do: errors

  defp add_errors(errors, messages), do: Enum.reduce(messages, errors, &[&1 | &2])
end
