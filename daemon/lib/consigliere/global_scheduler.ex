defmodule Consigliere.GlobalScheduler do
  @moduledoc """
  Global concurrency limiter. Phase 1 is a plain GenServer with limit 1
  (docs/architecture/runtime.md). Occupancy is a cache: on restart it is
  rebuilt from Attempt rows that currently hold a slot.

  Planned is included alongside running/starting/checkpoint_requested so a
  restart cannot double-grant a slot that was already given to a Mission
  whose Attempt has not spawned yet.
  """
  use GenServer

  import Ecto.Query

  alias Consigliere.Repo
  alias Consigliere.Attempts.Attempt

  @occupying ~w(planned starting running checkpoint_requested)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  def request_slot(mission_id) do
    GenServer.call(__MODULE__, {:request_slot, mission_id})
  end

  def release_slot(mission_id) do
    GenServer.call(__MODULE__, {:release_slot, mission_id})
  end

  def occupants do
    GenServer.call(__MODULE__, :occupants)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(opts) do
    env = Application.get_env(:consigliere_daemon, __MODULE__, [])
    limit = Keyword.get(opts, :limit, Keyword.get(env, :limit, 1))
    {:ok, %{limit: limit, occupants: rebuild_occupants()}}
  end

  @impl true
  def handle_call({:request_slot, mission_id}, _from, state) do
    cond do
      MapSet.member?(state.occupants, mission_id) ->
        {:reply, {:ok, :held}, state}

      MapSet.size(state.occupants) >= state.limit ->
        {:reply, {:error, :busy}, state}

      true ->
        {:reply, {:ok, :granted}, %{state | occupants: MapSet.put(state.occupants, mission_id)}}
    end
  end

  def handle_call({:release_slot, mission_id}, _from, state) do
    {:reply, :ok, %{state | occupants: MapSet.delete(state.occupants, mission_id)}}
  end

  def handle_call(:occupants, _from, state) do
    {:reply, MapSet.to_list(state.occupants), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | occupants: rebuild_occupants()}}
  end

  defp rebuild_occupants do
    Repo.all(from a in Attempt, where: a.status in ^@occupying, select: a.mission_id)
    |> MapSet.new()
  end
end
