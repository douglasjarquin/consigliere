defmodule Consigliere.Missions do
  @moduledoc false

  alias Consigliere.Missions.Transitions

  defdelegate create(attrs, actor), to: Transitions
  defdelegate submit_for_authorization(mission_id, actor), to: Transitions
  defdelegate request_changes(mission_id, actor), to: Transitions
  defdelegate start(mission_id, actor, opts), to: Transitions
  defdelegate mark_ready_for_review(mission_id, actor), to: Transitions
  defdelegate return_to_active(mission_id, actor, reason), to: Transitions
  defdelegate await_integration_authorization(mission_id, actor, attrs), to: Transitions
  defdelegate grant_integration_authorization(mission_id, actor, attrs), to: Transitions
  defdelegate complete_integration(mission_id, actor, attrs), to: Transitions
  defdelegate detect_integration_race(mission_id, actor, reason), to: Transitions
  defdelegate fail(mission_id, actor, attrs), to: Transitions
  defdelegate cancel(mission_id, actor, reason), to: Transitions
  defdelegate supersede(mission_id, actor, replacement_attrs), to: Transitions
  defdelegate resume_after_decision(mission_id, actor, decision_id), to: Transitions

  def grant_work_authorization(mission_id, actor, attrs \\ %{}) do
    Transitions.grant_work_authorization(mission_id, actor, attrs)
  end
end
