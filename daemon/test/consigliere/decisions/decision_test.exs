defmodule Consigliere.Decisions.DecisionTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Decisions.Decision

  test "a valid changeset inserts and round-trips" do
    attrs = %{scope: "mission_finding_waiver", granted_by_principal: "boss"}

    assert {:ok, decision} = Repo.insert(Decision.changeset(%Decision{}, attrs))
    assert Repo.get(Decision, decision.id).scope == "mission_finding_waiver"
  end

  test "an unknown scope is rejected" do
    attrs = %{scope: "nonsense", granted_by_principal: "boss"}
    refute Decision.changeset(%Decision{}, attrs).valid?
  end
end
