defmodule Consigliere.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info(
      "consigliere boot pid=#{System.pid()} command=#{inspect(System.get_env("RELEASE_COMMAND"))} " <>
        "os_command=#{inspect(os_env(~c"RELEASE_COMMAND"))} " <>
        "os_root=#{inspect(os_env(~c"RELEASE_ROOT"))} " <>
        "cs_home=#{inspect(System.get_env("CS_HOME"))} " <>
        "home=#{inspect(Consigliere.Home.dir())} children=#{length(children())}"
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
      Consigliere.Termination,
      Consigliere.GlobalScheduler,
      {Registry, keys: :unique, name: Consigliere.Registry},
      Consigliere.RunnerDynamicSupervisor,
      Consigliere.Reconciler,
      Consigliere.MissionDynamicSupervisor,
      Consigliere.MissionBootstrap,
      Consigliere.API.Supervisor
    ]
  end

  defp start_supervisor do
    # :one_for_one is deliberate: a crashed sibling must never kill unrelated work (see ADR-004).
    opts = [strategy: :one_for_one, name: Consigliere.Supervisor]
    home = Consigliere.Home.dir()

    # Mix release boot runs start.boot and elixir start_cli. Both call
    # Application.start. The second must reuse the live supervisor.
    result =
      case Supervisor.start_link(children(), opts) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end

    record_boot_result(result, home)
  end

  def lock_contention_outcome(home \\ Consigliere.Home.dir()) do
    case Consigliere.Home.lock_status(home) do
      {:held, _} -> :handoff
      _ -> if Consigliere.Home.socket_status(home) == :live, do: :handoff, else: :error
    end
  end

  # Losing the boot race to a live instance is expected contention, not a
  # bug -- socket_status/1 already surfaces :live independently, so
  # recording this here would just read as a false alarm next to a
  # perfectly healthy daemon. A release second-start should exit 0 so
  # the process holding stdout is not a failed CI step.
  def record_boot_result(
        {:error, {:shutdown, {:failed_to_start_child, Consigliere.Home.Lock, :already_running}}} =
          result,
        home
      ) do
    if lock_contention_outcome(home) == :handoff and halt_on_lock_contention?() do
      Logger.info("consigliere boot: CS_HOME already owned; this VM exits 0")
      System.halt(0)
    else
      result
    end
  end

  def record_boot_result({:ok, _pid} = result, home) do
    if Process.whereis(Consigliere.DatabaseWriter) do
      _ = Consigliere.CommandReceipts.reconcile_pending()
    end

    Consigliere.Home.clear_error!(home)
    result
  end

  def record_boot_result({:error, reason} = result, home) do
    Consigliere.Home.record_error!(home, inspect(reason))
    result
  end

  defp halt_on_lock_contention? do
    not Code.ensure_loaded?(Mix)
  end

  defp os_env(name) do
    case :os.getenv(name) do
      false -> nil
      value -> List.to_string(value)
    end
  end
end
