import Config

System.put_env("CS_HOME", Path.join(System.tmp_dir!(), "consigliere-daemon-test-home"))

config :consigliere_daemon, Consigliere.Repo, pool_size: 5

config :consigliere_daemon, Consigliere.EventBus, poll_interval_ms: :infinity

config :consigliere_daemon, Consigliere.OutboxDispatcher,
  poll_interval_ms: :infinity,
  drain_on_notify: false,
  lease_ms: 50,
  max_attempts: 3

config :consigliere_daemon, Consigliere.MissionCoordinator, poll_interval_ms: :infinity

config :consigliere_daemon, Consigliere.GlobalScheduler, limit: 1

config :consigliere_daemon, Consigliere.Reconciler,
  poll_interval_ms: :infinity,
  run_on_boot: false
