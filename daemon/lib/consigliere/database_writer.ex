defmodule Consigliere.DatabaseWriter do
  @moduledoc """
  The single serialized write path required by docs/adr/ADR-002 and
  docs/architecture/database.md.

  Every mutation in the system is expected to route through this one
  GenServer's mailbox. Because a GenServer processes its mailbox one
  message at a time, this turns "many concurrent writers" into "one
  writer at a time, queued," which is what actually avoids
  SQLITE_BUSY under WAL mode rather than relying on busy_timeout alone
  to paper over real write contention.

  This module holds no long-lived domain state in memory. Every call
  is a short `Repo.transaction/1` that reads what it needs, mutates,
  and returns. If the process crashes, nothing durable is lost,
  because nothing durable ever lived here, only in SQLite.
  """
  use GenServer

  alias Consigliere.Repo

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Insert a Mission through the serialized write path."
  def insert_mission(attrs) do
    Consigliere.Missions.create(attrs, Consigliere.Actor.system())
  end

  @doc """
  Run an arbitrary transaction function through the serialized write
  path. Exists for spike/test scenarios that need direct control
  (e.g. deliberately holding a transaction open, or writing a
  poison row via raw SQL). Production code should prefer named
  functions like insert_mission/1 over this escape hatch.
  """
  def transaction(fun, timeout \\ 10_000) do
    GenServer.call(__MODULE__, {:transaction, fun}, timeout)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:transaction, fun}, _from, state) do
    result =
      try do
        Repo.transaction(fun)
      rescue
        exception -> {:error, exception}
      end

    if match?({:ok, _}, result) do
      Consigliere.EventBus.notify()
      Consigliere.OutboxDispatcher.notify()
    end

    {:reply, result, state}
  end

end
