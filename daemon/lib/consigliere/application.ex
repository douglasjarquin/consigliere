defmodule Consigliere.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    with nil <- Consigliere.Home.forced_failure_reason() do
      start_supervisor()
    else
      reason ->
        Consigliere.Home.record_error!(reason)
        {:error, {:forced_startup_failure, reason}}
    end
  end

  defp start_supervisor do
    children = [
      Consigliere.Home.Lock,
      Consigliere.Repo,
      Consigliere.DatabaseWriter,
      {Registry, keys: :duplicate, name: Consigliere.EventBus.Registry},
      Consigliere.EventBus,
      Consigliere.OutboxDispatcher,
      Consigliere.GlobalScheduler,
      Consigliere.Reconciler,
      {Registry, keys: :unique, name: Consigliere.Registry},
      Consigliere.RunnerDynamicSupervisor,
      Consigliere.MissionDynamicSupervisor,
      Consigliere.API.Supervisor
    ]

    # :one_for_one is deliberate: a crashed sibling must never kill unrelated work (see ADR-004).
    opts = [strategy: :one_for_one, name: Consigliere.Supervisor]

    children
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
