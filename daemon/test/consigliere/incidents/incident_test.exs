defmodule Consigliere.Incidents.IncidentTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.Incidents.Incident

  test "a valid changeset inserts and round-trips, mission_id is optional" do
    attrs = %{severity: "terminal", reason: "repair budget exhausted"}

    assert {:ok, incident} = Repo.insert(Incident.changeset(%Incident{}, attrs))
    assert Repo.get(Incident, incident.id).severity == "terminal"
  end

  test "an incident can reference a mission" do
    mission = Fixtures.mission!()
    attrs = %{mission_id: mission.id, severity: "warning", reason: "flaky infra"}

    assert {:ok, incident} = Repo.insert(Incident.changeset(%Incident{}, attrs))
    assert Repo.get(Incident, incident.id).mission_id == mission.id
  end

  test "missing reason is rejected" do
    refute Incident.changeset(%Incident{}, %{severity: "terminal"}).valid?
  end
end
