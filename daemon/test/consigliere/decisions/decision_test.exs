defmodule Consigliere.Decisions.DecisionTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.Decisions.Decision
  alias Consigliere.Questions.Question

  test "a valid changeset inserts and round-trips" do
    attrs = %{scope: "mission_finding_waiver", granted_by_principal: "boss"}

    assert {:ok, decision} = Repo.insert(Decision.changeset(%Decision{}, attrs))
    assert Repo.get(Decision, decision.id).scope == "mission_finding_waiver"
  end

  test "question_id, expiry, and revocation bounds round-trip" do
    mission = Fixtures.mission!()
    attempt = Fixtures.attempt!(mission)

    {:ok, question} =
      Repo.insert(
        Question.changeset(%Question{}, %{
          mission_id: mission.id,
          attempt_id: attempt.id,
          request_id: "req-1",
          blocking_scope: "mission",
          requested_authority: "boss",
          status: "open",
          prompt: "proceed?"
        })
      )

    expires_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      mission_id: mission.id,
      question_id: question.id,
      scope: "sha_bound",
      granted_by_principal: "boss",
      expires_at: expires_at,
      maximum_uses: 1
    }

    assert {:ok, decision} = Repo.insert(Decision.changeset(%Decision{}, attrs))
    reloaded = Repo.get(Decision, decision.id)
    assert reloaded.question_id == question.id
    assert reloaded.maximum_uses == 1
    assert reloaded.expires_at == expires_at
  end

  test "an unknown scope is rejected" do
    attrs = %{scope: "nonsense", granted_by_principal: "boss"}
    refute Decision.changeset(%Decision{}, attrs).valid?
  end
end
