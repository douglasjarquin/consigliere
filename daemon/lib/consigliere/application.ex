defmodule Consigliere.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Consigliere.Repo,
      Consigliere.DatabaseWriter
    ]

    # :one_for_one is deliberate: a crashed sibling must never kill unrelated work (see ADR-004).
    opts = [strategy: :one_for_one, name: Consigliere.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
