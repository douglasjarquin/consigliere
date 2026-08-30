defmodule Consigliere.Attempts do
  @moduledoc false

  alias Consigliere.Attempts.Attempt
  alias Consigliere.AttemptStates
  alias Consigliere.GlobalScheduler
  alias Consigliere.Attempts.Transitions

  defdelegate schedule(mission_id, actor, attrs), to: Transitions
  defdelegate request_spawn(attempt_id, actor), to: Transitions
  defdelegate mark_running(attempt_id, actor, attrs), to: Transitions
  defdelegate mark_spawn_failed(attempt_id, actor, reason), to: Transitions
  defdelegate touch_last_event(attempt_id, actor, at), to: Transitions
  defdelegate report_progress(attempt_id, actor, attrs \\ %{}), to: Transitions
  defdelegate report_completion(attempt_id, actor, attrs \\ %{}), to: Transitions
  defdelegate report_failure(attempt_id, actor, attrs \\ %{}), to: Transitions
  defdelegate record_checkpointed(attempt_id, actor, attrs), to: Transitions
  defdelegate complete(attempt_id, actor, attrs), to: Transitions
  defdelegate fail(attempt_id, actor, attrs), to: Transitions
  defdelegate cancel(attempt_id, actor, attrs), to: Transitions
  defdelegate mark_lost(attempt_id, actor, attrs), to: Transitions
  defdelegate supersede(attempt_id, actor, replacement_attrs), to: Transitions

  def request_checkpoint(attempt_id, actor, attrs \\ %{}) do
    Transitions.request_checkpoint(attempt_id, actor, attrs)
  end

  def classify_exit(attempt_id, attrs) do
    with {:ok, attempt} <- Transitions.classify_exit(attempt_id, attrs) do
      Consigliere.Progression.after_classify(attempt, process_group: attrs[:process_group])

      if AttemptStates.terminal?(attempt.status),
        do: GlobalScheduler.release_slot(attempt.mission_id)

      {:ok, Consigliere.Repo.get!(Attempt, attempt_id)}
    end
  end
end
