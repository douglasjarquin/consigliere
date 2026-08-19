defmodule Consigliere.MissionCoordinator do
  use GenServer

  def start_link(opts) do
    mission_id = Keyword.fetch!(opts, :mission_id)
    GenServer.start_link(__MODULE__, opts, name: via(mission_id))
  end

  def via(mission_id), do: {:via, Registry, {Consigliere.Registry, {:mission, mission_id}}}

  def runner_pid(pid), do: GenServer.call(pid, :runner_pid)

  @impl true
  def init(opts) do
    attempt_id = Keyword.fetch!(opts, :attempt_id)
    mission_id = Keyword.fetch!(opts, :mission_id)

    runner_pid =
      case Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) do
        [{pid, _}] -> pid
        [] -> :not_found
      end

    {:ok, %{mission_id: mission_id, attempt_id: attempt_id, runner_pid: runner_pid}}
  end

  @impl true
  def handle_call(:runner_pid, _from, state), do: {:reply, state.runner_pid, state}
end
