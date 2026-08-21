defmodule Mix.Tasks.Cs.Migrate do
  use Mix.Task

  @shortdoc "Run Ecto migrations against CS_HOME/consigliere.db"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    :ok = Consigliere.Release.migrate()
    IO.puts(Consigliere.Home.database_path())
  end
end
