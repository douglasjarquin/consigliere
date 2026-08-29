defmodule Consigliere.RunnerProcess do
  @moduledoc """
  Daemon-side owner of one cs-runner control channel. The harness process
  group is owned by the external Go runner, not this GenServer (ADR-001,
  docs/protocols/runner.md). restart: :temporary: Attempts are disposable.
  """
  use GenServer
  require Logger

  alias Consigliere.Actor
  alias Consigliere.Adapters
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.ProcessGroup
  alias Consigliere.Repo
  alias Consigliere.RunnerLauncher
  alias Consigliere.Harness.UsageLedger
  alias Consigliere.Harness.Capture

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
    workspace_path = Keyword.get(opts, :workspace_path, "unbound")
    workspace_generation = Keyword.get(opts, :workspace_generation, "unbound")
    harness_command = harness_command(opts)

    runtime = runtime_dir(attempt_id)
    File.mkdir_p!(runtime)
    File.chmod!(runtime, 0o700)
    invocation_id = Keyword.get(opts, :invocation_id) || invocation_id()
    {invocation_runtime, control_socket_path} = invocation_runtime(runtime, invocation_id)
    File.mkdir_p!(invocation_runtime)
    File.chmod!(invocation_runtime, 0o700)

    case RunnerLauncher.launch(
           attempt_id: attempt_id,
           mission_id: mission_id,
           fencing_token: fencing_token,
           manifest_path: Path.join(runtime, "manifest.json"),
           control_socket_path: control_socket_path,
           invocation_id: invocation_id,
           workspace_path: workspace_path,
           workspace_generation: workspace_generation,
           harness_command: harness_command,
           env: runner_env(opts)
         ) do
      {:ok, session} ->
        :ok = :inet.setopts(session.socket, active: :once)
        maybe_persist_started(attempt_id, session, fencing_token, invocation_id)

        {:ok,
         %{
           attempt_id: attempt_id,
           mission_id: mission_id,
           fencing_token: fencing_token,
           session: session,
           invocation_id: invocation_id,
           project_id: Keyword.get(opts, :project_id),
           context_hash: Keyword.get(opts, :context_hash),
           policy: Keyword.get(opts, :policy, %{}),
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
    {:stop, state.stop_reason || manifest_exit_reason(state), state}
  end

  def handle_info({port, {:exit_status, status}}, %{session: %{port: port}} = state) do
    {:stop, state.stop_reason || {:harness_exited, status}, state}
  end

  def handle_info({:tcp, socket, line}, %{session: %{socket: socket}} = state) do
    case RunnerLauncher.verify_frame(state.session, String.trim(line)) do
      {:ok, message, session} ->
        :ok = :inet.setopts(socket, active: :once)
        {:noreply, handle_control(message, %{state | session: session})}

      {:error, _reason} ->
        :ok = :inet.setopts(socket, active: :once)
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{session: %{socket: socket}} = state) do
    {:stop, state.stop_reason || manifest_exit_reason(state), state}
  end

  def handle_info(other, state) do
    Logger.warning("Consigliere.RunnerProcess received unexpected message: #{inspect(other)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{session: session} = state) do
    _ = RunnerLauncher.cancel(session)
    _ = :gen_tcp.close(session.socket)
    if Port.info(session.port), do: Port.close(session.port)
    _ = RunnerLauncher.release(session)
    _ = classify_exit(reason, state)
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _), do: :ok

  defp handle_control(%{} = message, state) do
    case message do
      %{"fencing_token" => token} when token != state.fencing_token ->
        state

      msg ->
        handle_control_msg(msg, state)
    end
  end

  defp handle_control_msg(%{"type" => "stdout_chunk"} = msg, state) do
    data = Map.get(msg, "data", "")
    state = ingest_stdout(data, state)
    bump_heartbeat(state, data)
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
        Adapters.harness().argv(opts)
    end
  end

  defp runner_env(opts) do
    env = [
      {~c"CS_HOME", ~c""},
      {~c"CS_API_SOCKET", String.to_charlist(Consigliere.Home.api_socket_path())},
      {~c"CODEX_HOME", String.to_charlist(Consigliere.Home.ensure_codex_home!())}
    ]

    case Keyword.get(opts, :capability) do
      secret when is_binary(secret) ->
        [{~c"CS_CAPABILITY", String.to_charlist(secret)} | env]

      _ ->
        env
    end
  end

  defp ingest_stdout(data, state) do
    append_attempt_log(state.attempt_id, data)
    adapter = Adapters.harness()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :decode_line, 1) do
      data
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.reduce(state, fn line, st -> ingest_decoded(adapter.decode_line(line), st) end)
    else
      state
    end
  end

  defp ingest_decoded({:event, type, payload}, state) do
    seq = Map.get(state, :native_seq, 0) + 1

    result =
      Consigliere.Harness.Events.ingest(
        %{
          "event_id" => "#{type}-#{state.attempt_id}-#{seq}",
          "type" => type,
          "native_sequence" => seq,
          "attempt_id" => state.attempt_id,
          "payload" => payload
        },
        Actor.attempt(state.attempt_id, state.fencing_token)
      )

    case result do
      {:ok, outcome} when outcome in [:accepted, :duplicate] ->
        state = maybe_record_session(payload, state)

        maybe_record_usage(type, payload, state)
        |> Map.put(:native_seq, seq)

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp ingest_decoded(_, state), do: state

  defp append_attempt_log(attempt_id, data) do
    path = Path.join(Consigliere.Home.logs_dir(), "attempts/#{attempt_id}.log")

    case Capture.append(path, data) do
      :ok -> :ok
      {:error, reason} -> quarantine_capture(attempt_id, reason)
    end
  rescue
    _ -> :ok
  end

  defp quarantine_capture(attempt_id, reason) do
    with {:ok, id} <- Ecto.UUID.cast(attempt_id),
         %{workspace_id: workspace_id} <- Repo.get(Attempt, id),
         %{status: status} = workspace <- Repo.get(Consigliere.Workspaces.Workspace, workspace_id),
         true <- status not in ["quarantined", "released"] do
      _ = Consigliere.Workspaces.quarantine(workspace.id, Actor.system(), "capture_#{reason}")
    else
      _ -> :ok
    end
  end

  defp maybe_record_session(%{"native_session_id" => session_id}, state)
       when is_binary(session_id) and session_id != "" do
    Map.put(state, :native_session_id, String.slice(session_id, 0, 256))
  end

  defp maybe_record_session(_payload, state), do: state

  defp maybe_record_usage(type, payload, state)
       when type in ["usage.updated", "session.completed"] do
    usage = Map.get(payload, "usage", payload)
    sequence = Map.get(state, :native_seq, 0) + 1

    identity = %{
      system: "consigliere",
      project_id: state.project_id,
      mission_id: state.mission_id,
      attempt_id: state.attempt_id,
      session_id: Map.get(state, :native_session_id),
      sequence: sequence,
      correlation_id: "#{state.invocation_id}:#{sequence}",
      logical_key: "#{state.attempt_id}:#{type}",
      outcome: "accepted",
      model: state.policy["model"],
      effort: state.policy["effort"],
      cli_version: state.policy["cli_version"],
      context_hash: state.context_hash
    }

    _ = UsageLedger.record(identity, usage, Consigliere.Home.dir())
    state
  end

  defp maybe_record_usage(_type, _payload, state), do: state

  defp classify_exit(reason, state) do
    with {:ok, id} <- Ecto.UUID.cast(state.attempt_id),
         %Attempt{} = attempt <- Repo.get(Attempt, id) do
      {code, _} = exit_bits(reason, state)
      death = death_of(state)
      completed? = attempt.exit_classification == "completed"
      failed? = failed_class?(attempt)

      Attempts.classify_exit(id, %{
        process_group: death,
        exit_status: code,
        session_completed: completed?,
        session_failed: failed?,
        exit_classification: attempt.exit_classification
      })
    else
      _ -> :ok
    end
  end

  defp failed_class?(%Attempt{exit_classification: klass})
       when is_binary(klass) and klass not in ["completed", "canceled"] do
    true
  end

  defp failed_class?(_), do: false

  defp death_of(%{session: %{pgid: pgid}}) when is_integer(pgid) and pgid > 1 do
    ProcessGroup.terminate(pgid)
  end

  defp death_of(_), do: :dead_verified

  defp exit_bits({:harness_exited, code}, _), do: {code, :exited}
  defp exit_bits(:normal, _), do: {0, :normal}
  defp exit_bits(_, %{stop_reason: {:harness_exited, code}}), do: {code, :exited}
  defp exit_bits(_, %{stop_reason: :normal}), do: {0, :normal}
  defp exit_bits(_, _), do: {nil, :unknown}

  defp manifest_exit_reason(%{session: %{manifest_path: manifest_path}}) do
    case File.read(manifest_path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"state" => "dead_verified", "exit_code" => code}}
          when is_integer(code) and code != 0 ->
            {:harness_exited, code}

          _ ->
            :normal
        end

      _ ->
        :normal
    end
  end

  defp manifest_exit_reason(_), do: :normal

  defp runtime_dir(attempt_id) do
    Path.join(Consigliere.Home.runtime_attempts_dir(), to_string(attempt_id))
  end

  defp invocation_id do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp invocation_runtime(runtime, invocation_id) do
    preferred = Path.join(runtime, "i-#{invocation_id}")

    if byte_size(Path.join(preferred, "c.sock")) < 104 do
      {preferred, Path.join(preferred, "c.sock")}
    else
      short = Path.join(Consigliere.Home.runtime_attempts_dir(), "i-#{invocation_id}")
      {short, Path.join(short, "c.sock")}
    end
  end

  defp maybe_persist_started(attempt_id, session, fencing_token, invocation_id) do
    with {:ok, id} <- Ecto.UUID.cast(attempt_id),
         %Attempt{status: "starting"} <- Repo.get(Attempt, id) do
      Attempts.mark_running(id, Actor.system(), %{
        fencing_token: fencing_token,
        runner_pid: session.runner_os_pid,
        harness_pid: session.harness_pid,
        pgid: session.pgid,
        invocation_id: invocation_id
      })
    else
      _ -> :ok
    end
  end
end
