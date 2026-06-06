defmodule MirrorNeuron.Runtime.SchedulePolicy do
  @moduledoc false

  @default_grace_ms 60_000
  @default_catchup_limit 10
  @supported_kinds ["periodic", "delayed", "event", "resource_wait"]
  @supported_missed_policies ["skip", "catchup_one", "catchup_all"]
  @supported_end_actions ["cancel", "none"]

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
      case next_cron_after(cron, after_dt) do
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
      "schedule.window.end_action must be cancel or none"
    )
  end

  defp invalid_cron_errors(crons) do
    crons
    |> Enum.reject(fn cron -> match?({:ok, _}, parse_cron(cron)) end)
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

  defp next_cron_after(cron, after_dt) do
    with {:ok, spec} <- parse_cron(cron) do
      after_dt
      |> DateTime.add(60 - after_dt.second, :second)
      |> DateTime.truncate(:second)
      |> find_next_matching_minute(spec, 0)
    end
  end

  defp find_next_matching_minute(_candidate, _spec, minutes) when minutes > 366 * 24 * 60,
    do: {:error, :no_match}

  defp find_next_matching_minute(candidate, spec, minutes) do
    if cron_matches?(candidate, spec) do
      {:ok, candidate}
    else
      candidate
      |> DateTime.add(60, :second)
      |> find_next_matching_minute(spec, minutes + 1)
    end
  end

  defp parse_cron("@hourly"), do: parse_cron("0 * * * *")
  defp parse_cron("@daily"), do: parse_cron("0 0 * * *")
  defp parse_cron("@weekly"), do: parse_cron("0 0 * * 0")
  defp parse_cron("@monthly"), do: parse_cron("0 0 1 * *")
  defp parse_cron("@yearly"), do: parse_cron("0 0 1 1 *")
  defp parse_cron("@annually"), do: parse_cron("@yearly")

  defp parse_cron(cron) when is_binary(cron) do
    case String.split(cron, ~r/\s+/, trim: true) do
      [minute, hour, day, month, dow] ->
        with {:ok, minute_values} <- parse_field(minute, 0, 59),
             {:ok, hour_values} <- parse_field(hour, 0, 23),
             {:ok, day_values} <- parse_field(day, 1, 31),
             {:ok, month_values} <- parse_field(month, 1, 12),
             {:ok, dow_values} <- parse_field(dow, 0, 7) do
          {:ok,
           %{
             minute: minute_values,
             hour: hour_values,
             day: day_values,
             month: month_values,
             dow:
               MapSet.new(
                 Enum.map(dow_values, fn
                   7 -> 0
                   value -> value
                 end)
               ),
             day_any: day == "*",
             dow_any: dow == "*"
           }}
        end

      _ ->
        {:error, :invalid_cron}
    end
  end

  defp parse_cron(_cron), do: {:error, :invalid_cron}

  defp parse_field(field, min, max) do
    field
    |> String.split(",", trim: true)
    |> Enum.reduce_while(MapSet.new(), fn part, acc ->
      case parse_field_part(part, min, max) do
        {:ok, values} -> {:cont, MapSet.union(acc, values)}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      %MapSet{} = values -> {:ok, values}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_field_part(part, min, max) do
    [range_part, step_part] =
      case String.split(part, "/", parts: 2) do
        [range] -> [range, "1"]
        [range, step] -> [range, step]
      end

    with {step, ""} <- Integer.parse(step_part),
         true <- step > 0,
         {:ok, first, last} <- parse_range(range_part, min, max) do
      {:ok, MapSet.new(Enum.take_every(first..last, step))}
    else
      _ -> {:error, :invalid_field}
    end
  end

  defp parse_range("*", min, max), do: {:ok, min, max}

  defp parse_range(range, min, max) do
    case String.split(range, "-", parts: 2) do
      [single] ->
        with {value, ""} <- Integer.parse(single),
             true <- value >= min and value <= max do
          {:ok, value, value}
        else
          _ -> {:error, :invalid_range}
        end

      [left, right] ->
        with {first, ""} <- Integer.parse(left),
             {last, ""} <- Integer.parse(right),
             true <- first >= min and last <= max and first <= last do
          {:ok, first, last}
        else
          _ -> {:error, :invalid_range}
        end
    end
  end

  defp cron_matches?(datetime, spec) do
    day_matches = MapSet.member?(spec.day, datetime.day)
    dow_matches = MapSet.member?(spec.dow, rem(Date.day_of_week(DateTime.to_date(datetime)), 7))

    day_or_dow =
      cond do
        spec.day_any and spec.dow_any -> true
        spec.day_any -> dow_matches
        spec.dow_any -> day_matches
        true -> day_matches or dow_matches
      end

    MapSet.member?(spec.minute, datetime.minute) and
      MapSet.member?(spec.hour, datetime.hour) and
      MapSet.member?(spec.month, datetime.month) and
      day_or_dow
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
