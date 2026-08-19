defmodule Mix.Tasks.Cs.Doctor do
  use Mix.Task

  alias Consigliere.Home

  @shortdoc "Diagnose the consigliere daemon's home-directory state"

  @impl Mix.Task
  def run(_args) do
    home = Home.dir()

    case Home.socket_status(home) do
      :live ->
        Mix.shell().info("daemon running (home: #{home})")

      :stale ->
        Mix.shell().info(
          "stale socket at #{Home.boss_socket_path(home)} -- will be cleaned up on next start"
        )

      :absent ->
        Mix.shell().info("daemon not running (home: #{home})")
    end

    case Home.last_error(home) do
      nil -> :ok
      reason -> Mix.shell().info("last startup failure: #{reason}")
    end
  end
end
