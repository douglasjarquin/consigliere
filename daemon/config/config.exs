import Config

config :consigliere_daemon,
  ecto_repos: [Consigliere.Repo],
  harness_adapter: Consigliere.Harness.Codex,
  made_adapter: Consigliere.Made.Process,
  github_adapter: Consigliere.GitHub.Gh

config :consigliere_daemon, Consigliere.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: Path.expand("priv/consigliere_#{config_env()}.db", File.cwd!()),
  journal_mode: :wal,
  busy_timeout: 5_000,
  pool_size: 5

import_config "#{config_env()}.exs"
