defmodule Consigliere.RunnerProcessRecoveryTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.DomainEvents.DomainEvent
  alias Consigliere.Fixtures
  alias Consigliere.GlobalScheduler
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.Repo
  alias Consigliere.Attempts.Attempt
  alias Consigliere.RunnerLauncher
  alias Consigliere.RunnerProcess
  alias Consigliere.Runtime.Inventory

  setup do
    Fixtures.reset_phase1_tables!()
    GlobalScheduler.reset()
    :ok
  end

  test "a harness exit cannot overwrite a protocol-failure persistence marker" do
    {mission, attempt} = Fixtures.starting_attempt!()
    attempt_id = attempt.id
    heartbeat_file = Path.join(System.tmp_dir!(), "#{attempt_id}.hb")

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        mission_id: mission.id,
        fencing_token: attempt.fencing_token,
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

  test "a failed running persistence transition tears down the handshaken runner" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    {:ok, mission} = Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, attempt} =
      Repo.insert(
        Attempt.changeset(%Attempt{}, %{
          mission_id: mission.id,
          role: "soldier",
          harness: "fake",
          status: "starting",
          fencing_token: "durable-fence"
        })
      )

    attempt_id = attempt.id

    result =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        mission_id: mission.id,
        fencing_token: "stale-fence",
        harness_command: ["sleep", "30"]
      )

    assert {:error, {:runner_identity_persist_failed, {:fenced, ^attempt_id}}} = result
    assert Repo.get!(Attempt, attempt.id).status == "failed"
    assert Registry.lookup(Consigliere.Registry, {:runner, attempt.id}) == []

    manifest_path = Inventory.path_for(Home.dir(), attempt.id)

    assert eventually(fn -> terminal_manifest?(manifest_path) end)
  end

  test "a missing Attempt cannot accept a handshaken runner" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    attempt_id = Ecto.UUID.generate()
    mission_id = Ecto.UUID.generate()

    result =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        mission_id: mission_id,
        fencing_token: "missing-attempt-fence",
        harness_command: ["sleep", "30"]
      )

    case result do
      {:error, {:runner_identity_persist_failed, :attempt_not_found}} ->
        :ok

      {:ok, pid} ->
        os_pid = RunnerProcess.os_pid(pid)

        on_exit(fn ->
          if Process.alive?(pid), do: RunnerProcess.cancel(pid)
          Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
        end)

        flunk("a runner started without a durable Attempt")

      other ->
        flunk("unexpected startup result: #{inspect(other)}")
    end

    assert Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) == []

    manifest_path = Inventory.path_for(Home.dir(), attempt_id)
    assert eventually(fn -> terminal_manifest?(manifest_path) end)
  end

  test "an Attempt outside starting cannot accept a handshaken runner" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    mission = Fixtures.mission!()
    attempt = Fixtures.attempt!(mission, %{status: "completed"})

    result =
      RunnerProcess.start_link(
        attempt_id: attempt.id,
        mission_id: mission.id,
        fencing_token: attempt.fencing_token,
        harness_command: ["sleep", "30"]
      )

    assert {:error, {:runner_identity_persist_failed, {:attempt_not_starting, "completed"}}} =
             result

    assert Registry.lookup(Consigliere.Registry, {:runner, attempt.id}) == []

    manifest_path = Inventory.path_for(Home.dir(), attempt.id)
    assert eventually(fn -> terminal_manifest?(manifest_path) end)
  end

  test "an invalid Attempt identifier cannot accept a handshaken runner" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    attempt_id = "not-an-attempt-id"
    mission_id = Ecto.UUID.generate()

    result =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        mission_id: mission_id,
        fencing_token: "invalid-attempt-fence",
        harness_command: ["sleep", "30"]
      )

    assert {:error, {:runner_identity_persist_failed, :invalid_attempt_id}} = result
    assert Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) == []

    manifest_path = Inventory.path_for(Home.dir(), attempt_id)
    assert eventually(fn -> terminal_manifest?(manifest_path) end)
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

  defp eventually(fun, remaining \\ 100)

  defp eventually(fun, remaining) when remaining > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, remaining - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp terminal_manifest?(path) do
    case File.read(path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"state" => state}} when state in ["dead_verified", "dead_unverified"] -> true
          _ -> false
        end

      _ ->
        false
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

    {:ok, capability} = Consigliere.Capabilities.mint(attempt)
    {:ok, capability_record} = Consigliere.Capabilities.authenticate(capability)
    {attempt, mission, workspace, capability, capability_record}
  end
end
