defmodule Consigliere.OutboxDispatcher do
  @moduledoc """
  Drains `outbox_items` with per-destination handlers.

  The outbox row is authoritative. This process holds only the in-flight
  item it is currently dispatching. A crash leaves the row `leased`
  until `leased_until`; a later drain reclaims it. Handlers run *outside*
  any SQLite transaction (docs/architecture/database.md).

  Kinds without a registered handler are left queued. Notification
  delivery is Phase 4 (`NotificationDispatcher`); this increment only
  owns the lease/retry/complete loop.
  """
  use GenServer

  alias Consigliere.OutboxItems.Transitions
  alias Consigliere.Txn

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  def notify do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :drain)
    end

    :ok
  end

  def drain do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, 0}
      pid -> GenServer.call(pid, :drain_all, 30_000)
    end
  end

  def put_handler(kind, fun) when is_binary(kind) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:put_handler, kind, fun})
  end

  def clear_handlers do
    GenServer.call(__MODULE__, :clear_handlers)
  end

  @impl true
  def init(opts) do
    env = Application.get_env(:consigliere_daemon, __MODULE__, [])
    interval = Keyword.get(opts, :poll_interval_ms, Keyword.get(env, :poll_interval_ms, 500))

    drain_on_notify =
      Keyword.get(opts, :drain_on_notify, Keyword.get(env, :drain_on_notify, true))

    lease_ms = Keyword.get(opts, :lease_ms, Keyword.get(env, :lease_ms, 15_000))
    max_attempts = Keyword.get(opts, :max_attempts, Keyword.get(env, :max_attempts, 8))
    handlers = Map.merge(Keyword.get(env, :handlers, %{}), Keyword.get(opts, :handlers, %{}))

    schedule_tick(interval)

    {:ok,
     %{
       poll_interval_ms: interval,
       drain_on_notify: drain_on_notify,
       lease_ms: lease_ms,
       max_attempts: max_attempts,
       handlers: handlers
     }}
  end

  @impl true
  def handle_call(:drain_all, _from, state) do
    {:reply, {:ok, drain_loop(state, 0)}, state}
  end

  def handle_call({:put_handler, kind, fun}, _from, state) do
    {:reply, :ok, %{state | handlers: Map.put(state.handlers, kind, fun)}}
  end

  def handle_call(:clear_handlers, _from, state) do
    {:reply, :ok, %{state | handlers: %{}}}
  end

  @impl true
  def handle_info(:drain, state) do
    if state.drain_on_notify do
      _ = drain_loop(state, 0)
    end

    {:noreply, state}
  end

  def handle_info(:tick, state) do
    _ = drain_loop(state, 0)
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  defp drain_loop(state, n) do
    kinds = Map.keys(state.handlers)

    if kinds == [] do
      n
    else
      case claim_one(state, kinds) do
        nil ->
          n

        item ->
          dispatch(item, state)
          drain_loop(state, n + 1)
      end
    end
  end

  defp claim_one(state, kinds) do
    now = Txn.now()
    lease_until = DateTime.add(now, state.lease_ms, :millisecond)

    case Transitions.claim_due(kinds, now, lease_until) do
      {:ok, nil} -> nil
      {:ok, item} -> item
      {:error, _} -> nil
    end
  end

  defp dispatch(item, state) do
    handler = Map.fetch!(state.handlers, item.kind)

    result =
      try do
        handler.(item)
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end

    case result do
      :ok ->
        Transitions.complete(item.id)

      {:ok, _} ->
        Transitions.complete(item.id)

      {:already_done, _} ->
        Transitions.complete(item.id)

      {:error, error} ->
        fail_or_retry(item, state, to_string(error))

      other ->
        fail_or_retry(item, state, "unexpected handler result: #{inspect(other)}")
    end
  end

  defp fail_or_retry(item, state, error) do
    if item.attempts >= state.max_attempts do
      Transitions.fail(item.id, error)
    else
      backoff_s = min(60, Integer.pow(2, max(item.attempts - 1, 0)))
      next = DateTime.add(Txn.now(), backoff_s, :second)
      Transitions.retry(item.id, error, next)
    end
  end

  defp schedule_tick(:infinity), do: :ok

  defp schedule_tick(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
  end
end
