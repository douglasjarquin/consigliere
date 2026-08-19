defmodule Consigliere.RunnerProcess do
  use GenServer
  require Logger

  # An Attempt is disposable (ADR-004): its death must never trigger an
  # implicit same-identity respawn. A replacement Attempt is always an
  # explicit new start_child from higher-level scheduling, never a
  # supervisor auto-restart under the same attempt_id.
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(opts) do
    attempt_id = Keyword.fetch!(opts, :attempt_id)
    GenServer.start_link(__MODULE__, opts, name: via(attempt_id))
  end

  def via(attempt_id), do: {:via, Registry, {Consigliere.Registry, {:runner, attempt_id}}}

  def os_pid(pid), do: GenServer.call(pid, :os_pid)

  def heartbeat_count(pid), do: GenServer.call(pid, :heartbeat_count)

  @impl true
  def init(opts) do
    heartbeat_file = Keyword.fetch!(opts, :heartbeat_file)
    max_iterations = Keyword.get(opts, :max_iterations)
    script = Path.join(:code.priv_dir(:consigliere_daemon), "fake_harness.sh")

    args =
      if max_iterations, do: [heartbeat_file, to_string(max_iterations)], else: [heartbeat_file]

    port =
      Port.open({:spawn_executable, script}, [
        :binary,
        :exit_status,
        args: args
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    {:ok, %{port: port, os_pid: os_pid, heartbeat_count: 0}}
  end

  @impl true
  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  @impl true
  def handle_call(:heartbeat_count, _from, state), do: {:reply, state.heartbeat_count, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    lines = data |> String.split("\n", trim: true) |> length()
    {:noreply, %{state | heartbeat_count: state.heartbeat_count + lines}}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:harness_exited, status}, state}
  end

  def handle_info(other, state) do
    Logger.warning("Consigliere.RunnerProcess received unexpected message: #{inspect(other)}")
    {:noreply, state}
  end
end
