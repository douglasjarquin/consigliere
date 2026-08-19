defmodule Consigliere.Attempts do
  @moduledoc false

  alias Consigliere.Attempts.Transitions

  defdelegate schedule(mission_id, actor, attrs), to: Transitions
  defdelegate request_spawn(attempt_id, actor), to: Transitions
  defdelegate mark_running(attempt_id, actor, attrs), to: Transitions
  defdelegate mark_spawn_failed(attempt_id, actor, reason), to: Transitions
  defdelegate touch_last_event(attempt_id, actor, at), to: Transitions
  defdelegate record_checkpointed(attempt_id, actor, attrs), to: Transitions
  defdelegate complete(attempt_id, actor, attrs), to: Transitions
  defdelegate fail(attempt_id, actor, attrs), to: Transitions
  defdelegate cancel(attempt_id, actor, attrs), to: Transitions
  defdelegate mark_lost(attempt_id, actor, attrs), to: Transitions
  defdelegate supersede(attempt_id, actor, replacement_attrs), to: Transitions

  def request_checkpoint(attempt_id, actor, attrs \\ %{}) do
    Transitions.request_checkpoint(attempt_id, actor, attrs)
  end
end
