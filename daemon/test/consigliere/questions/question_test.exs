defmodule Consigliere.Questions.QuestionTest do
  use ExUnit.Case, async: true

  alias Consigliere.Repo
  alias Consigliere.Fixtures
  alias Consigliere.Questions.Question

  defp attrs(mission, attempt, overrides \\ %{}) do
    Map.merge(
      %{
        mission_id: mission.id,
        attempt_id: attempt.id,
        request_id: "req-1",
        blocking_scope: "attempt",
        requested_authority: "boss",
        status: "open",
        prompt: "which approach?"
      },
      overrides
    )
  end

  test "a valid changeset inserts and round-trips" do
    mission = Fixtures.mission!()
    attempt = Fixtures.attempt!(mission)

    assert {:ok, question} = Repo.insert(Question.changeset(%Question{}, attrs(mission, attempt)))
    assert Repo.get(Question, question.id).status == "open"
  end

  test "an unknown blocking_scope is rejected" do
    mission = Fixtures.mission!()
    attempt = Fixtures.attempt!(mission)

    changeset =
      Question.changeset(%Question{}, attrs(mission, attempt, %{blocking_scope: "nonsense"}))

    refute changeset.valid?
  end

  test "the same request_id from the same Attempt is rejected as a duplicate (idempotency dedup)" do
    mission = Fixtures.mission!()
    attempt = Fixtures.attempt!(mission)

    assert {:ok, _} = Repo.insert(Question.changeset(%Question{}, attrs(mission, attempt)))

    assert {:error, changeset} =
             Repo.insert(Question.changeset(%Question{}, attrs(mission, attempt)))

    assert "has already been taken" in errors_for(changeset, :request_id)
  end

  defp errors_for(changeset, field) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Map.get(field, [])
  end
end
