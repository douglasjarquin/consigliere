defmodule Consigliere.Attempts do
  @moduledoc false

  alias Consigliere.Attempts.Attempt
  alias Consigliere.AttemptStates
  alias Consigliere.GlobalScheduler
  alias Consigliere.Attempts.Transitions
  alias Consigliere.DispatchOperations

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

      case reconcile_terminal_slot(attempt_id, attrs[:process_group]) do
        :ok -> {:ok, Consigliere.Repo.get!(Attempt, attempt_id)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def release_scheduler_slot(attempt_id) do
    case Consigliere.Repo.get(Attempt, attempt_id) do
      %Attempt{mission_id: mission_id, status: status} = attempt ->
        if AttemptStates.terminal?(status) do
          case DispatchOperations.get_by_attempt(attempt.id) do
            nil ->
              GlobalScheduler.release_slot(mission_id)

            %{slot_state: "released"} ->
              GlobalScheduler.release_slot(mission_id)

            %{slot_state: slot_state} ->
              {:error, {:dispatch_slot_not_released, slot_state}}
          end
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  defp reconcile_terminal_slot(attempt_id, process_group) do
    case Consigliere.Repo.get(Attempt, attempt_id) do
      %Attempt{status: status} when not is_nil(status) ->
        if AttemptStates.terminal?(status) do
          persist_result =
            if process_group == :dead_verified do
              DispatchOperations.release_slot(attempt_id)
            else
              DispatchOperations.hold_slot(attempt_id)
            end

          case persist_result do
            {:ok, _} when process_group == :dead_verified ->
              release_scheduler_slot(attempt_id)

            {:ok, _} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        else
          :ok
        end

      nil ->
        :ok
    end
  end
end
