import Config

config :consigliere_daemon, Consigliere.EventBus, poll_interval_ms: 500

config :consigliere_daemon, Consigliere.OutboxDispatcher,
  poll_interval_ms: 500,
  drain_on_notify: true,
  lease_ms: 15_000,
  max_attempts: 8

config :consigliere_daemon, Consigliere.MissionCoordinator, poll_interval_ms: 1_000

config :consigliere_daemon, Consigliere.GlobalScheduler, limit: 1

config :consigliere_daemon, Consigliere.Reconciler,
  poll_interval_ms: 5_000,
  run_on_boot: true
