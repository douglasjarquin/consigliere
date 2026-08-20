defmodule Consigliere.EventBus do
  @moduledoc """
  In-process republisher of committed `domain_events` rows.

  Not a durability mechanism: the row is already committed by
  DatabaseWriter before this process ever sees it. Subscribers recover
  from a missed beat by polling `id > last_seen_id` themselves
  (docs/architecture/database.md). This process is a convenience so a
  live MissionCoordinator can react without waiting for its own poll.
  """
  use GenServer

  import Ecto.Query

  alias Consigliere.Repo
  alias Consigliere.DomainEvents.DomainEvent

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  def subscribe(pid \\ self()) do
    Registry.register(Consigliere.EventBus.Registry, :events, pid)
    :ok
  end

  def notify do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :poll)
    end

    :ok
  end

  def poll do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :poll)
    end
  end

  def last_seen_id do
    case Process.whereis(__MODULE__) do
      nil -> 0
      pid -> GenServer.call(pid, :last_seen_id)
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :poll_interval_ms, poll_interval_ms())
    last_seen_id = current_max_id()
    schedule_tick(interval)
    {:ok, %{last_seen_id: last_seen_id, poll_interval_ms: interval}}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {:reply, :ok, do_poll(state)}
  end

  def handle_call(:last_seen_id, _from, state) do
    {:reply, state.last_seen_id, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, do_poll(state)}
  end

  def handle_info(:tick, state) do
    state = do_poll(state)
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  defp do_poll(state) do
    events =
      Repo.all(
        from(e in DomainEvent,
          where: e.id > ^state.last_seen_id,
          order_by: [asc: e.id]
        )
      )

    Enum.each(events, &dispatch/1)

    case List.last(events) do
      nil -> state
      last -> %{state | last_seen_id: last.id}
    end
  end

  defp dispatch(event) do
    Registry.dispatch(Consigliere.EventBus.Registry, :events, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:domain_event, event}) end)
    end)
  end

  defp current_max_id do
    Repo.one(from(e in DomainEvent, select: max(e.id))) || 0
  end

  defp schedule_tick(:infinity), do: :ok

  defp schedule_tick(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
  end

  defp poll_interval_ms do
    Application.get_env(:consigliere_daemon, __MODULE__, [])
    |> Keyword.get(:poll_interval_ms, 500)
  end
end
