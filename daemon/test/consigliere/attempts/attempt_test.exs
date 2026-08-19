defmodule Consigliere.Attempts.AttemptTest do
  use ExUnit.Case, async: true

  import Consigliere.ChangesetHelpers

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.Attempts.Attempt

  test "a valid changeset inserts and round-trips" do
    mission = Fixtures.mission!()
    workspace = Fixtures.workspace!(mission)

    attrs = %{
      mission_id: mission.id,
      workspace_id: workspace.id,
      role: "soldier",
      harness: "claude",
      status: "planned",
      fencing_token: "fence-1"
    }

    assert {:ok, attempt} = Repo.insert(Attempt.changeset(%Attempt{}, attrs))
    assert Repo.get(Attempt, attempt.id).status == "planned"
  end

  test "an unknown status is rejected" do
    mission = Fixtures.mission!()

    attrs = %{
      mission_id: mission.id,
      role: "soldier",
      harness: "claude",
      status: "not_a_real_status",
      fencing_token: "fence-1"
    }

    refute Attempt.changeset(%Attempt{}, attrs).valid?
  end

  test "reported_checkpoint_sha round-trips" do
    mission = Fixtures.mission!()

    attrs = %{
      mission_id: mission.id,
      role: "soldier",
      harness: "claude",
      status: "checkpoint_requested",
      fencing_token: "fence-1",
      reported_checkpoint_sha: "abc123"
    }

    assert {:ok, attempt} = Repo.insert(Attempt.changeset(%Attempt{}, attrs))
    assert Repo.get(Attempt, attempt.id).reported_checkpoint_sha == "abc123"
  end

  test "retry_of_attempt_id self-references another Attempt" do
    mission = Fixtures.mission!()
    original = Fixtures.attempt!(mission)

    attrs = %{
      mission_id: mission.id,
      role: "soldier",
      harness: "claude",
      status: "planned",
      fencing_token: "fence-2",
      retry_of_attempt_id: original.id
    }

    assert {:ok, retry} = Repo.insert(Attempt.changeset(%Attempt{}, attrs))
    assert Repo.get(Attempt, retry.id).retry_of_attempt_id == original.id
  end

  test "a nonexistent mission_id is rejected by the foreign key constraint" do
    attrs = %{
      mission_id: Ecto.UUID.generate(),
      role: "soldier",
      harness: "claude",
      status: "planned",
      fencing_token: "fence-1"
    }

    assert {:error, changeset} = Repo.insert(Attempt.changeset(%Attempt{}, attrs))
    assert %{mission_id: ["does not exist"]} = errors_on(changeset)
  end
end
