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
    workspace_id = Keyword.get(opts, :workspace_id)
    base_sha = Keyword.get(opts, :base_sha)
    parent_checkpoint_sha = Keyword.get(opts, :parent_checkpoint_sha)
    capability = Keyword.get(opts, :capability)
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
           capability: capability,
           capability_id: Keyword.get(opts, :capability_id),
           capability_generation: Keyword.get(opts, :capability_generation),
           workspace_id: workspace_id,
           workspace_generation: workspace_generation,
           base_sha: base_sha,
           parent_checkpoint_sha: parent_checkpoint_sha,
           project_id: Keyword.get(opts, :project_id),
           context_hash: Keyword.get(opts, :context_hash),
           policy: Keyword.get(opts, :policy, %{}),
           heartbeat_count: 0,
           stdout_buffer: "",
           stdout_discarding: false,
           stdout_native_sequence: 0,
           stderr_native_sequence: 0,
           stop_reason: nil,
           harness_exit_received: false,
           port_exit_status: nil
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
    if state.harness_exit_received do
      {:stop, state.stop_reason || manifest_exit_reason(state), state}
    else
      {:noreply, %{state | port_exit_status: 0}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{session: %{port: port}} = state) do
    if state.harness_exit_received do
      {:stop, state.stop_reason || {:harness_exited, status}, state}
    else
      {:noreply, %{state | port_exit_status: status}}
    end
  end

  def handle_info({:tcp, socket, line}, %{session: %{socket: socket}} = state) do
    case RunnerLauncher.verify_frame(state.session, String.trim(line)) do
      {:ok, message, session} ->
        :ok = :inet.setopts(socket, active: :once)
        state = handle_control(message, %{state | session: session})

        if state.harness_exit_received and not is_nil(state.port_exit_status) do
          {:stop, state.stop_reason || manifest_exit_reason(state), state}
        else
          {:noreply, state}
        end

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
    case accept_stream_sequence(msg, :stdout_native_sequence, state) do
      {:ok, state} ->
        data = Map.get(msg, "data", "")
        state = ingest_stdout(data, state)
        bump_heartbeat(state, data)

      {:duplicate, state} ->
        state

      {:error, state} ->
        state
    end
  end

  defp handle_control_msg(%{"type" => "stderr_chunk"} = msg, state) do
    case accept_stream_sequence(msg, :stderr_native_sequence, state) do
      {:ok, state} ->
        data = Map.get(msg, "data", "")
        append_attempt_log(state.attempt_id, data)
        bump_heartbeat(state, data)

      {:duplicate, state} ->
        state

      {:error, state} ->
        state
    end
  end

  defp handle_control_msg(%{"type" => "harness_exited", "exit_code" => 0}, state) do
    %{state | stop_reason: :normal, harness_exit_received: true}
  end

  defp handle_control_msg(%{"type" => "harness_exited", "exit_code" => code}, state) do
    %{state | stop_reason: {:harness_exited, code}, harness_exit_received: true}
  end

  defp handle_control_msg(_msg, state), do: state

  defp bump_heartbeat(state, data) do
    lines = data |> to_string() |> String.split("\n", trim: true) |> length()
    inc = if lines > 0, do: lines, else: 1
    %{state | heartbeat_count: state.heartbeat_count + inc}
  end

  defp accept_stream_sequence(msg, key, state) do
    last = Map.get(state, key, 0)
    sequence = Map.get(msg, "native_sequence")

    cond do
      is_integer(sequence) and sequence == last + 1 ->
        {:ok, Map.put(state, key, sequence)}

      is_integer(sequence) and sequence >= 1 and sequence <= last ->
        {:duplicate, state}

      true ->
        {:error, mark_protocol_failure(state, stream_sequence_error(sequence, last))}
    end
  end

  defp stream_sequence_error(sequence, last)
       when is_integer(sequence) and sequence > last + 1,
       do: "stream_sequence_gap"

  defp stream_sequence_error(_sequence, _last), do: "stream_sequence_invalid"

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
      {~c"CODEX_HOME", String.to_charlist(Consigliere.Home.ensure_codex_home!())},
      {~c"CS_ATTEMPT_BRIDGE", ~c"1"},
      {~c"CS_ATTEMPT_BIN",
       String.to_charlist(Path.join(:code.priv_dir(:consigliere_daemon), "cs-attempt"))}
    ]

    env = add_env(env, ~c"CS_ATTEMPT_ID", Keyword.get(opts, :attempt_id))
    env = add_env(env, ~c"CS_MISSION_ID", Keyword.get(opts, :mission_id))
    env = add_env(env, ~c"CS_PROJECT_ID", Keyword.get(opts, :project_id))
    env = add_env(env, ~c"CS_WORKSPACE_ID", Keyword.get(opts, :workspace_id))
    env = add_env(env, ~c"CS_WORKSPACE_GENERATION", Keyword.get(opts, :workspace_generation))
    env = add_env(env, ~c"CS_BASE_SHA", Keyword.get(opts, :base_sha))
    env = add_env(env, ~c"CS_PARENT_CHECKPOINT_SHA", Keyword.get(opts, :parent_checkpoint_sha))
    env = add_env(env, ~c"CS_FENCING_GENERATION", Keyword.get(opts, :fencing_token))
    env = add_env(env, ~c"CS_CAPABILITY_ID", Keyword.get(opts, :capability_id))
    env = add_env(env, ~c"CS_CAPABILITY_GENERATION", Keyword.get(opts, :capability_generation))

    env
  end

  defp add_env(env, _key, nil), do: env
  defp add_env(env, _key, ""), do: env
  defp add_env(env, key, value), do: [{key, String.to_charlist(to_string(value))} | env]

  defp report_attempt(operation, payload, state) do
    result_kind = if operation == "complete", do: "completed", else: "checkpoint"

    report =
      %{
        "attempt_id" => state.attempt_id,
        "mission_id" => state.mission_id,
        "project_id" => state.project_id,
        "workspace_id" => state.workspace_id,
        "workspace_generation" => state.workspace_generation,
        "base_sha" => state.base_sha,
        "fencing_generation" => state.fencing_token,
        "result_sha" => Map.get(payload, "result_sha"),
        "result_kind" => result_kind,
        "terminal_sequence" => "latest"
      }
      |> maybe_put_report_parent(state.parent_checkpoint_sha)

    idempotency_key = "attempt:#{state.attempt_id}:#{operation}"

    request = %{
      "v" => 1,
      "id" => idempotency_key,
      "op" => "attempt.#{operation}",
      "actor" => %{"principal" => "attempt"},
      "capability" => state.capability,
      "idempotency_key" => idempotency_key,
      "operation_version" => 1,
      "payload" => report
    }

    response = Consigliere.API.Protocol.handle(JSON.encode!(request), :capability)

    case JSON.decode(response) do
      {:ok, %{"ok" => true}} ->
        state

      {:ok, %{"ok" => false, "error" => %{"code" => code}}} ->
        mark_protocol_failure(state, code)

      {:ok, _response} ->
        mark_protocol_failure(state, "invalid_bridge_response")

      {:error, _reason} ->
        mark_protocol_failure(state, "invalid_bridge_response")
    end
  rescue
    _exception -> mark_protocol_failure(state, "bridge_exception")
  end

  defp mark_protocol_failure(state, code) do
    actor =
      Actor.attempt(
        state.attempt_id,
        state.fencing_token,
        ["attempt.fail"],
        %{
          capability_id: state.capability_id,
          capability_generation: state.capability_generation,
          mission_id: state.mission_id,
          workspace_id: state.workspace_id,
          workspace_generation: state.workspace_generation
        }
      )

    failure_code =
      case Attempts.report_failure(state.attempt_id, actor, %{classification: "protocol_failure"}) do
        {:ok, _attempt} -> code
        {:error, reason} -> "#{code}:failure_persist_failed:#{inspect(reason)}"
      end

    %{state | stop_reason: {:protocol_failure, to_string(failure_code) |> String.slice(0, 128)}}
  end

  defp maybe_put_report_parent(report, nil), do: report

  defp maybe_put_report_parent(report, parent),
    do: Map.put(report, "parent_checkpoint_sha", parent)

  defp ingest_stdout(data, state) do
    append_attempt_log(state.attempt_id, data)
    adapter = Adapters.harness()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :decode_line, 1) do
      input = stdout_input(state.stdout_buffer, state.stdout_discarding, to_string(data))
      {lines, remainder} = split_stdout_lines(input)
      {remainder, discarding} = bounded_stdout_remainder(remainder)
      state = %{state | stdout_buffer: remainder, stdout_discarding: discarding}

      Enum.reduce(lines, state, fn line, st ->
        if byte_size(line) <= Consigliere.V0.Limits.frame_bytes() do
          ingest_decoded(adapter.decode_line(line), st)
        else
          st
        end
      end)
    else
      state
    end
  end

  defp stdout_input(_buffer, true, data) do
    case :binary.match(data, "\n") do
      {index, 1} -> binary_part(data, index + 1, byte_size(data) - index - 1)
      :nomatch -> ""
    end
  end

  defp stdout_input(buffer, false, data), do: buffer <> data

  defp split_stdout_lines(input) do
    case :binary.split(input, "\n", [:global]) do
      [remainder] ->
        {[], remainder}

      parts ->
        {remainder, lines} = List.pop_at(parts, -1)
        {lines, remainder}
    end
  end

  defp bounded_stdout_remainder(remainder) do
    if byte_size(remainder) > Consigliere.V0.Limits.frame_bytes() do
      {"", true}
    else
      {remainder, false}
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

  defp ingest_decoded({:attempt_report, operation, payload}, state)
       when operation in ["complete", "checkpoint"] do
    report_attempt(operation, payload, state)
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
      failed? = failed_class?(attempt) or protocol_failure?(state)

      Attempts.classify_exit(id, %{
        process_group: death,
        exit_status: code,
        session_completed: completed?,
        session_failed: failed?,
        exit_classification: attempt.exit_classification || protocol_failure_classification(state)
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

  defp protocol_failure?(%{stop_reason: {:protocol_failure, _}}), do: true
  defp protocol_failure?(_), do: false

  defp protocol_failure_classification(state) do
    if protocol_failure?(state), do: "protocol_failure"
  end

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
