defmodule Consigliere.RunnerProcessRecoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.DomainEvents.DomainEvent
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.Missions
  alias Consigliere.Repo
  alias Consigliere.RunnerLauncher
  alias Consigliere.RunnerProcess

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  test "a harness exit cannot overwrite a protocol-failure persistence marker" do
    attempt_id = "recovery-#{System.unique_integer([:positive])}"
    heartbeat_file = Path.join(System.tmp_dir!(), "#{attempt_id}.hb")

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        heartbeat_file: heartbeat_file,
        harness_command: ["sleep", "5"]
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(heartbeat_file)
    end)

    :sys.replace_state(pid, fn state ->
      %{state | stop_reason: {:protocol_failure, "bridge_failure:failure_persist_failed"}}
    end)

    state = :sys.get_state(pid)

    frame =
      RunnerLauncher.encode_frame(
        state.session,
        %{"type" => "harness_exited", "exit_code" => 0},
        state.session.recv_seq + 1
      )

    send(pid, {:tcp, state.session.socket, JSON.encode!(frame) <> "\n"})
    Process.sleep(80)

    assert :sys.get_state(pid).stop_reason ==
             {:protocol_failure, "bridge_failure:failure_persist_failed"}
  end

  test "repeated native sequence gaps record only one protocol failure" do
    {attempt, mission, workspace, capability, capability_record} =
      running_attempt_with_capability!()

    heartbeat_file = Path.join(System.tmp_dir!(), "#{attempt.id}.hb")

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: attempt.id,
        mission_id: attempt.mission_id,
        project_id: mission.project_id,
        workspace_id: attempt.workspace_id,
        workspace_generation: workspace.lease_id,
        fencing_token: attempt.fencing_token,
        capability: capability,
        capability_id: capability_record.id,
        capability_generation: capability_record.generation,
        heartbeat_file: heartbeat_file,
        harness_command: ["sleep", "5"]
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(heartbeat_file)
    end)

    state = :sys.get_state(pid)

    frame = fn current_state ->
      RunnerLauncher.encode_frame(
        current_state.session,
        %{
          "type" => "stdout_chunk",
          "data" => "out-of-order\n",
          "native_sequence" => 2
        },
        current_state.session.recv_seq + 1
      )
    end

    send(pid, {:tcp, state.session.socket, JSON.encode!(frame.(state)) <> "\n"})
    wait_until(fn -> length(failure_events(attempt.id)) == 1 end)

    next_state = :sys.get_state(pid)
    send(pid, {:tcp, next_state.session.socket, JSON.encode!(frame.(next_state)) <> "\n"})
    Process.sleep(80)

    assert length(failure_events(attempt.id)) == 1
    assert {:protocol_failure, reason} = :sys.get_state(pid).stop_reason
    assert reason == "stream_sequence_gap"
  end

  defp failure_events(attempt_id) do
    Repo.all(
      from(e in DomainEvent,
        where: e.subject_type == "attempt" and e.subject_id == ^attempt_id,
        where: e.type == "attempt.failure_reported"
      )
    )
  end

  defp wait_until(fun, remaining \\ 100) do
    if fun.() do
      :ok
    else
      if remaining <= 0 do
        flunk("condition did not become true")
      else
        Process.sleep(50)
        wait_until(fun, remaining - 1)
      end
    end
  end

  defp running_attempt_with_capability! do
    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())
    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, _mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{attempt: attempt, workspace: workspace}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-recovery-#{System.unique_integer([:positive])}"
      })

    {:ok, attempt} = Attempts.request_spawn(attempt.id, Actor.system())

    {:ok, attempt} =
      Attempts.mark_running(attempt.id, Actor.system(), %{fencing_token: attempt.fencing_token})

    {:ok, capability} = Consigliere.Capabilities.mint(attempt)
    {:ok, capability_record} = Consigliere.Capabilities.authenticate(capability)
    {attempt, mission, workspace, capability, capability_record}
  end
end
