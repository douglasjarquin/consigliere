defmodule Consigliere.EventBusTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.EventBus
  alias Consigliere.Fixtures
  alias Consigliere.Missions

  setup do
    Fixtures.reset_phase1_tables!()
    EventBus.poll()
    :ok
  end

  test "a committed write is republished to subscribers in id order" do
    EventBus.subscribe()

    {:ok, first} =
      Missions.create(Fixtures.mission_attrs(%{objective: "one"}), Actor.system())

    {:ok, second} =
      Missions.create(Fixtures.mission_attrs(%{objective: "two"}), Actor.system())

    EventBus.poll()

    assert_receive {:domain_event, %{type: "mission.created", subject_id: id1}}, 1_000
    assert_receive {:domain_event, %{type: "mission.created", subject_id: id2}}, 1_000
    assert id1 == first.id
    assert id2 == second.id
  end

  test "DatabaseWriter still commits if EventBus is down" do
    pid = Process.whereis(EventBus)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    assert {:ok, mission} =
             Missions.create(
               Fixtures.mission_attrs(%{objective: "survives"}),
               Actor.system()
             )

    assert mission.objective == "survives"
  end

  test "a restarted EventBus delivers events committed after the restart" do
    pid = Process.whereis(EventBus)
    old = pid
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    new_pid =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case Process.whereis(EventBus) do
          pid when is_pid(pid) and pid != old ->
            {:halt, pid}

          _ ->
            Process.sleep(10)
            {:cont, nil}
        end
      end)

    assert is_pid(new_pid)
    refute new_pid == pid

    EventBus.subscribe()

    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(%{objective: "after-restart"}), Actor.system())

    EventBus.poll()
    assert_receive {:domain_event, %{type: "mission.created", subject_id: id}}, 1_000
    assert id == mission.id
  end
end
