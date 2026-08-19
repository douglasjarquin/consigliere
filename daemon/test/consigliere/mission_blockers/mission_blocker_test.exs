defmodule Consigliere.MissionBlockers.MissionBlockerTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.MissionBlockers.MissionBlocker

  test "a valid changeset inserts and round-trips" do
    mission = Fixtures.mission!()
    attrs = %{mission_id: mission.id, kind: "question", status: "open"}

    assert {:ok, blocker} = Repo.insert(MissionBlocker.changeset(%MissionBlocker{}, attrs))
    assert Repo.get(MissionBlocker, blocker.id).kind == "question"
  end

  test "subject_type and subject_id round-trip as the polymorphic pointer" do
    mission = Fixtures.mission!()
    subject_id = Ecto.UUID.generate()

    attrs = %{
      mission_id: mission.id,
      kind: "question",
      status: "open",
      subject_type: "question",
      subject_id: subject_id
    }

    assert {:ok, blocker} = Repo.insert(MissionBlocker.changeset(%MissionBlocker{}, attrs))
    reloaded = Repo.get(MissionBlocker, blocker.id)
    assert reloaded.subject_type == "question"
    assert reloaded.subject_id == subject_id
  end

  test "an unknown status is rejected" do
    mission = Fixtures.mission!()
    attrs = %{mission_id: mission.id, kind: "question", status: "nonsense"}

    refute MissionBlocker.changeset(%MissionBlocker{}, attrs).valid?
  end
end
