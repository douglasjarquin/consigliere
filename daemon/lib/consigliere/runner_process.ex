defmodule Consigliere.RunnerProcess do
  @moduledoc """
  Daemon-side owner of one cs-runner control channel. The harness process
  group is owned by the external Go runner, not this GenServer (ADR-001,
  docs/protocols/runner.md). restart: :temporary: Attempts are disposable.
  """
  use GenServer
  require Logger

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Repo
  alias Consigliere.RunnerLauncher

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(opts) do
    attempt_id = Keyword.fetch!(opts, :attempt_id)
    GenServer.start_link(__MODULE__, opts, name: via(attempt_id))
  end

  def via(attempt_id), do: {:via, Registry, {Consigliere.Registry, {:runner, attempt_id}}}

  def os_pid(pid), do: GenServer.call(pid, :os_pid)

  def harness_pid(pid), do: GenServer.call(pid, :os_pid)

  def heartbeat_count(pid), do: GenServer.call(pid, :heartbeat_count)

  def cancel(pid), do: GenServer.call(pid, :cancel)

  @impl true
  def init(opts) do
    RunnerLauncher.ensure_binary!()

    attempt_id = Keyword.fetch!(opts, :attempt_id)
    mission_id = Keyword.get(opts, :mission_id, "none")
    fencing_token = Keyword.get(opts, :fencing_token, "fence-#{attempt_id}")
    harness_command = harness_command(opts)

    runtime = runtime_dir(attempt_id)
    File.mkdir_p!(runtime)

    case RunnerLauncher.launch(
           attempt_id: attempt_id,
           mission_id: mission_id,
           fencing_token: fencing_token,
           manifest_path: Path.join(runtime, "manifest.json"),
           control_socket_path: Path.join(runtime, "control.sock"),
           harness_command: harness_command
         ) do
      {:ok, session} ->
        :ok = :inet.setopts(session.socket, active: :once)
        maybe_persist_started(attempt_id, session, fencing_token)

        {:ok,
         %{
           attempt_id: attempt_id,
           fencing_token: fencing_token,
           session: session,
           heartbeat_count: 0,
           stop_reason: nil
         }}

      {:error, reason} ->
        {:stop, {:spawn_failed, reason}}
    end
  end

  @impl true
  def handle_call(:os_pid, _from, state), do: {:reply, state.session.harness_pid, state}

  def handle_call(:heartbeat_count, _from, state), do: {:reply, state.heartbeat_count, state}

  def handle_call(:cancel, _from, state) do
    _ = RunnerLauncher.cancel(state.session)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{session: %{port: port}} = state) do
    lines = data |> String.split("\n", trim: true) |> length()
    {:noreply, %{state | heartbeat_count: state.heartbeat_count + lines}}
  end

  def handle_info({port, {:exit_status, 0}}, %{session: %{port: port}} = state) do
    {:stop, state.stop_reason || :normal, state}
  end

  def handle_info({port, {:exit_status, status}}, %{session: %{port: port}} = state) do
    {:stop, state.stop_reason || {:harness_exited, status}, state}
  end

  def handle_info({:tcp, socket, line}, %{session: %{socket: socket}} = state) do
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, handle_control(String.trim(line), state)}
  end

  def handle_info({:tcp_closed, socket}, %{session: %{socket: socket}} = state) do
    {:stop, state.stop_reason || :normal, state}
  end

  def handle_info(other, state) do
    Logger.warning("Consigliere.RunnerProcess received unexpected message: #{inspect(other)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{session: session}) do
    _ = RunnerLauncher.cancel(session)
    _ = :gen_tcp.close(session.socket)
    if Port.info(session.port), do: Port.close(session.port)
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _), do: :ok

  defp handle_control(line, state) do
    case JSON.decode(line) do
      {:ok, %{"fencing_token" => token}} when token != state.fencing_token ->
        state

      {:ok, msg} ->
        handle_control_msg(msg, state)

      {:error, _} ->
        state
    end
  end

  defp handle_control_msg(%{"type" => "stdout_chunk"} = msg, state) do
    bump_heartbeat(state, Map.get(msg, "data", ""))
  end

  defp handle_control_msg(%{"type" => "harness_exited", "exit_code" => 0}, state) do
    %{state | stop_reason: :normal}
  end

  defp handle_control_msg(%{"type" => "harness_exited", "exit_code" => code}, state) do
    %{state | stop_reason: {:harness_exited, code}}
  end

  defp handle_control_msg(_msg, state), do: state

  defp bump_heartbeat(state, data) do
    lines = data |> to_string() |> String.split("\n", trim: true) |> length()
    inc = if lines > 0, do: lines, else: 1
    %{state | heartbeat_count: state.heartbeat_count + inc}
  end

  defp harness_command(opts) do
    case Keyword.get(opts, :harness_command) do
      command when is_list(command) and command != [] ->
        command

      _ ->
        script = Path.join(:code.priv_dir(:consigliere_daemon), "fake_harness.sh")
        heartbeat_file = Keyword.fetch!(opts, :heartbeat_file)
        args = [script, heartbeat_file]

        case Keyword.get(opts, :max_iterations) do
          nil -> args
          n -> args ++ [to_string(n)]
        end
    end
  end

  defp runtime_dir(attempt_id) do
    Path.join(["/tmp", "csr-#{System.unique_integer([:positive])}", attempt_id])
  end

  defp maybe_persist_started(attempt_id, session, fencing_token) do
    with {:ok, id} <- Ecto.UUID.cast(attempt_id),
         %Attempt{status: "starting"} <- Repo.get(Attempt, id) do
      Attempts.mark_running(id, Actor.system(), %{
        fencing_token: fencing_token,
        runner_pid: session.runner_os_pid,
        harness_pid: session.harness_pid,
        pgid: session.pgid
      })
    else
      _ -> :ok
    end
  end
end
