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
      {Registry, keys: :unique, name: Consigliere.Registry},
      Consigliere.RunnerDynamicSupervisor,
      Consigliere.MissionDynamicSupervisor
    ]

    # :one_for_one is deliberate: a crashed sibling must never kill unrelated work (see ADR-004).
    opts = [strategy: :one_for_one, name: Consigliere.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
