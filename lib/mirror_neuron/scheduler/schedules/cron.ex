defmodule MirrorNeuron.Scheduler.Schedules.Cron do
  @moduledoc "Parses five-field UTC cron expressions and finds the next matching minute."

  def next_cron_after(cron, after_dt) do
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

  def parse_cron("@hourly"), do: parse_cron("0 * * * *")

  def parse_cron("@daily"), do: parse_cron("0 0 * * *")

  def parse_cron("@weekly"), do: parse_cron("0 0 * * 0")

  def parse_cron("@monthly"), do: parse_cron("0 0 1 * *")

  def parse_cron("@yearly"), do: parse_cron("0 0 1 1 *")

  def parse_cron("@annually"), do: parse_cron("@yearly")

  def parse_cron(cron) when is_binary(cron) do
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

  def parse_cron(_cron), do: {:error, :invalid_cron}

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
end
