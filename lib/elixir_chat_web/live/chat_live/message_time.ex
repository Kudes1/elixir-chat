defmodule ElixirChatWeb.ChatLive.MessageTime do
  @moduledoc false

  @default_time_zone "Etc/UTC"
  @months ~w(января февраля марта апреля мая июня июля августа сентября октября ноября декабря)

  def localize(datetime, time_zone) do
    case DateTime.shift_zone(datetime, time_zone) do
      {:ok, local_datetime} -> local_datetime
      {:error, _reason} -> DateTime.shift_zone!(datetime, @default_time_zone)
    end
  end

  def current_year(time_zone) do
    DateTime.utc_now()
    |> localize(time_zone)
    |> Map.fetch!(:year)
  end

  def date_label(%Date{} = date, current_year) do
    base = "#{date.day} #{Enum.at(@months, date.month - 1)}"

    if date.year == current_year, do: base, else: "#{base} #{date.year}"
  end

  def full_datetime_label(%DateTime{} = datetime) do
    date = DateTime.to_date(datetime)

    "#{date.day} #{Enum.at(@months, date.month - 1)} #{date.year}, #{time_label(datetime)} (#{datetime.time_zone})"
  end

  def time_label(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M")
end
