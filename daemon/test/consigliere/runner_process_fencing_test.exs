defmodule Consigliere.RunnerProcessFencingTest do
  use ExUnit.Case, async: false

  alias Consigliere.Fixtures
  alias Consigliere.RunnerProcess
  alias Consigliere.RunnerLauncher

  test "stdout_chunk with a stale fencing_token is ignored" do
    heartbeat_file =
      Path.join(System.tmp_dir!(), "fence-#{System.unique_integer([:positive])}.hb")

    {mission, attempt} = Fixtures.starting_attempt!()
    attempt_id = attempt.id
    token = attempt.fencing_token

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        mission_id: mission.id,
        heartbeat_file: heartbeat_file,
        fencing_token: token
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(heartbeat_file)
    end)

    Process.sleep(150)
    before = RunnerProcess.heartbeat_count(pid)
    %{session: %{socket: socket}} = :sys.get_state(pid)

    session = :sys.get_state(pid).session
    next_seq = session.recv_seq + 1

    stale =
      session
      |> RunnerLauncher.encode_frame(
        %{
          "type" => "stdout_chunk",
          "data" => String.duplicate("stale\n", 80)
        },
        next_seq
      )
      |> Map.put("fencing_token", "stale-#{attempt_id}")
      |> JSON.encode!()

    send(pid, {:tcp, socket, stale <> "\n"})
    Process.sleep(80)

    assert RunnerProcess.heartbeat_count(pid) < before + 20,
           "a stale fencing token must not create heartbeat state"

    live_state = :sys.get_state(pid)
    live_session = live_state.session

    live =
      live_session
      |> RunnerLauncher.encode_frame(
        %{
          "type" => "stdout_chunk",
          "data" => String.duplicate("live\n", 80),
          "native_sequence" => live_state.stdout_native_sequence + 1
        },
        live_session.recv_seq + 1
      )
      |> JSON.encode!()

    assert {:ok, _message, _session} =
             RunnerLauncher.verify_frame(live_session, live <> "\n")

    send(pid, {:tcp, socket, live <> "\n"})
    Process.sleep(80)

    assert RunnerProcess.heartbeat_count(pid) >= before + 80
  end

  test "a gapped native stream sequence records a protocol failure" do
    {mission, attempt} = Fixtures.starting_attempt!()
    attempt_id = attempt.id
    heartbeat_file = Path.join(System.tmp_dir!(), "#{attempt_id}.hb")
    token = attempt.fencing_token

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        mission_id: mission.id,
        heartbeat_file: heartbeat_file,
        fencing_token: token,
        harness_command: ["sleep", "5"]
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(heartbeat_file)
    end)

    %{session: %{socket: socket} = session} = :sys.get_state(pid)

    frame =
      RunnerLauncher.encode_frame(
        session,
        %{
          "type" => "stdout_chunk",
          "data" => "out-of-order\n",
          "native_sequence" => 2
        },
        session.recv_seq + 1
      )

    send(pid, {:tcp, socket, JSON.encode!(frame) <> "\n"})
    Process.sleep(80)

    assert {:protocol_failure, reason} = :sys.get_state(pid).stop_reason
    assert String.starts_with?(reason, "stream_sequence_gap")
    assert RunnerProcess.heartbeat_count(pid) == 0
  end
end
