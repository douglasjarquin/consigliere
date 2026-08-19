import Config

System.put_env("CS_HOME", Path.join(System.tmp_dir!(), "consigliere-daemon-test-home"))

config :consigliere_daemon, Consigliere.Repo, pool_size: 5
