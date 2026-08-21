defmodule Consigliere.Repo do
  use Ecto.Repo,
    otp_app: :consigliere_daemon,
    adapter: Ecto.Adapters.SQLite3

  def init(_type, config) do
    home = Consigliere.Home.ensure_dir!()
    db = Consigliere.Home.database_path(home)

    {:ok,
     config
     |> Keyword.put(:database, db)
     |> Keyword.put_new(:journal_mode, :wal)
     |> Keyword.put_new(:busy_timeout, 5_000)}
  end
end
