defmodule Consigliere.Harness.ContextPack do
  @moduledoc """
  Bounded Soldier context pack. The hash is persisted on the Attempt;
  the pack itself is not a transcript replay.
  """

  def compose(mission, extras \\ %{}) do
    pack = %{
      "objective" => mission.objective,
      "scope" => mission.scope,
      "acceptance_criteria" => mission.acceptance_criteria,
      "project_id" => mission.project_id,
      "mission_id" => mission.id,
      "checkpoint_sha" => mission.current_checkpoint_sha,
      "authority" => %{
        "may_grant_work" => false,
        "may_grant_integration" => false,
        "may_answer_boss_questions" => false
      },
      "completion" => %{
        "require_checkpoint" => true,
        "require_session_completed" => true
      }
    }

    pack = Map.merge(pack, stringify(extras))
    encoded = JSON.encode!(pack)
    hash = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
    %{pack: pack, encoded: encoded, hash: hash}
  end

  defp stringify(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
