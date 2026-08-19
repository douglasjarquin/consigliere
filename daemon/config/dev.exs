import Config

config :consigliere_daemon, Consigliere.EventBus, poll_interval_ms: 500

config :consigliere_daemon, Consigliere.OutboxDispatcher,
  poll_interval_ms: 500,
  drain_on_notify: true,
  lease_ms: 15_000,
  max_attempts: 8
