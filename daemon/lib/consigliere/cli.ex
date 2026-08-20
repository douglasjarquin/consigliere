defmodule Consigliere.CLI do
  @moduledoc false

  alias Consigliere.Home

  # Plain IO.puts, not Mix.shell(): this must run from `bin/consigliere_daemon
  # eval` in a real release, where Mix is not loaded.
  def doctor do
    home = Home.dir()

    case Home.socket_status(home) do
      :live ->
        IO.puts("daemon running (home: #{home})")

      :stale ->
        IO.puts(
          "stale socket at #{Home.boss_socket_path(home)} -- will be cleaned up on next start"
        )

      :absent ->
        IO.puts("daemon not running (home: #{home})")
    end

    case Home.last_error(home) do
      nil -> :ok
      reason -> IO.puts("last startup failure: #{reason}")
    end
  end

  def away do
    Consigliere.Away.mark()
    IO.puts("away")
  end

  def return do
    digest = Consigliere.Away.return()
    n = length(digest["questions"])
    IO.puts("return: #{n} open question(s)")

    Enum.each(digest["questions"], fn q ->
      IO.puts("- #{q["id"]} #{q["prompt"]}")
    end)
  end
end

