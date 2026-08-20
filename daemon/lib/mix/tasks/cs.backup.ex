defmodule Mix.Tasks.Cs.Backup do
  use Mix.Task

  @shortdoc "VACUUM INTO a SQLite backup under CS_HOME"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    dest = List.first(args) || default_dest()
    {:ok, path} = Consigliere.Backup.backup(dest)
    IO.puts(path)
  end

  defp default_dest do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "")
    Path.join(Consigliere.Home.dir(), "backups/consigliere-#{stamp}.db")
  end
end
