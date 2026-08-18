defmodule Consigliere.Repo do
  use Ecto.Repo,
    otp_app: :consigliere_daemon,
    adapter: Ecto.Adapters.SQLite3
end
