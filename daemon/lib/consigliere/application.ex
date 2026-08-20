defmodule Consigliere.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info(
      "consigliere boot command=#{inspect(System.get_env("RELEASE_COMMAND"))} children=#{length(children())}"
    )

    with nil <- Consigliere.Home.forced_failure_reason() do
      start_supervisor()
    else
      reason ->
        Consigliere.Home.record_error!(reason)
        {:error, {:forced_startup_failure, reason}}
    end
  end

  # Mix release eval/rpc/remote must not take CS_HOME or bind sockets.
  # Ecto.Migrator.with_repo starts Repo on its own.
  def children(command \\ System.get_env("RELEASE_COMMAND"))

  def children(command) when command in ["eval", "rpc", "remote"], do: []

  def children(_command) do
    [
      Consigliere.Home.Lock,
      Consigliere.Repo,
      Consigliere.DatabaseWriter,
      {Registry, keys: :duplicate, name: Consigliere.EventBus.Registry},
      Consigliere.EventBus,
      Consigliere.OutboxDispatcher,
      Consigliere.NotificationDispatcher,
      Consigliere.Termination,
      Consigliere.GlobalScheduler,
      Consigliere.Reconciler,
      {Registry, keys: :unique, name: Consigliere.Registry},
      Consigliere.RunnerDynamicSupervisor,
      Consigliere.MissionDynamicSupervisor,
      Consigliere.MissionBootstrap,
      Consigliere.API.Supervisor
    ]
  end

  defp start_supervisor do
    # :one_for_one is deliberate: a crashed sibling must never kill unrelated work (see ADR-004).
    opts = [strategy: :one_for_one, name: Consigliere.Supervisor]

    children()
    |> Supervisor.start_link(opts)
    |> record_boot_result(Consigliere.Home.dir())
  end

  # Losing the boot race to a live instance is expected contention, not a
  # bug -- socket_status/1 already surfaces :live independently, so
  # recording this here would just read as a false alarm next to a
  # perfectly healthy daemon.
  def record_boot_result(
        {:error, {:shutdown, {:failed_to_start_child, Consigliere.Home.Lock, :already_running}}} =
          result,
        _home
      ) do
    result
  end

  def record_boot_result({:ok, _pid} = result, home) do
    Consigliere.Home.clear_error!(home)
    result
  end

  def record_boot_result({:error, reason} = result, home) do
    Consigliere.Home.record_error!(home, inspect(reason))
    result
  end
end
