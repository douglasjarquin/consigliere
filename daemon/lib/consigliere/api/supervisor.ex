defmodule Consigliere.API.Supervisor do
  @moduledoc """
  Owns the CLI/API Unix socket. Connection workers are temporary: a crash
  affects only that client (docs/architecture/runtime.md).
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {DynamicSupervisor, name: Consigliere.API.ConnectionSupervisor, strategy: :one_for_one},
      listener_spec(
        :api_listener,
        Keyword.merge(opts, name: Consigliere.API.Listener, which: :api)
      ),
      listener_spec(
        :privileged_listener,
        Keyword.merge(opts, name: Consigliere.API.PrivilegedListener, which: :privileged)
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp listener_spec(id, opts) do
    %{id: id, start: {Consigliere.API.Listener, :start_link, [opts]}}
  end
end
