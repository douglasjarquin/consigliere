defmodule Consigliere.Termination do
  @moduledoc """
  Durable runner cancellation. Process signaling happens outside any
  SQLite transaction. Slot and workspace stay occupied until death is
  verified.
  """
  use GenServer

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Capabilities
  alias Consigliere.GlobalScheduler
  alias Consigliere.OutboxItems.OutboxItem
  alias Consigliere.ProcessGroup
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.OutboxDispatcher
  alias Consigliere.Workspaces

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    _ = OutboxDispatcher.put_handler("runner_cancel", &deliver/1)
    {:ok, %{}}
  end

  def request_live_attempts!(mission, cause) do
    live = ~w(starting running checkpoint_requested checkpointed)

    from(a in Attempt, where: a.mission_id == ^mission.id and a.status in ^live)
    |> Repo.all()
    |> Enum.each(fn attempt ->
      request_attempt!(attempt, cause)
    end)

    from(a in Attempt, where: a.mission_id == ^mission.id and a.status == "planned")
    |> Repo.all()
    |> Enum.each(fn attempt ->
      Txn.update!(Attempt.changeset(attempt, %{status: "canceled", finished_at: Txn.now()}))
      Txn.append_event!("attempt.canceled", "attempt", attempt.id, %{cause: to_string(cause)})
    end)
  end

  def request_attempt!(attempt, cause) do
    token = Txn.mint_fencing_token()

    attempt =
      Txn.update!(Attempt.changeset(attempt, %{status: "terminating", fencing_token: token}))

    Txn.append_event!("attempt.termination_requested", "attempt", attempt.id, %{
      cause: to_string(cause)
    })

    Txn.insert!(
      OutboxItem.changeset(%OutboxItem{}, %{
        kind: "runner_cancel",
        status: "queued",
        idempotency_key: "attempt.cancel:#{attempt.id}:#{attempt.fencing_token}",
        natural_key: "attempt.cancel:#{attempt.id}",
        next_attempt_at: Txn.now(),
        payload: %{
          "attempt_id" => attempt.id,
          "mission_id" => attempt.mission_id,
          "cause" => to_string(cause),
          "pgid" => attempt.pgid
        }
      })
    )

    _ = Capabilities.revoke_for_attempt(attempt.id)
    attempt
  end

  def deliver(item) do
    attempt_id = item.payload["attempt_id"]
    cause = item.payload["cause"] || "canceled"
    cancel_runner(attempt_id)
    finalize(attempt_id, cause)
  end

  def cancel_runner(attempt_id) do
    case Registry.lookup(Consigliere.Registry, {:runner, attempt_id}) do
      [{pid, _}] -> Consigliere.RunnerProcess.cancel(pid)
      _ -> :ok
    end
  end

  def finalize(attempt_id, cause) do
    attempt = Repo.get(Attempt, attempt_id)

    cond do
      is_nil(attempt) ->
        :ok

      attempt.status in ~w(completed failed lost canceled superseded) ->
        release_if_idle(attempt)
        :ok

      true ->
        death = verify_death(attempt)

        cond do
          death == :dead_verified ->
            _ = apply_cause(attempt, cause, death)
            release_if_idle(attempt)
            :ok

          true ->
            quarantine(attempt)
            {:error, :death_unverified}
        end
    end
  end

  defp apply_cause(attempt, cause, death) do
    attrs = %{process_group: death, exit_classification: to_string(cause)}

    case cause do
      "failed" -> Attempts.fail(attempt.id, Actor.system(), attrs)
      "superseded" -> Attempts.cancel(attempt.id, Actor.system(), attrs)
      _ -> Attempts.cancel(attempt.id, Actor.system(), attrs)
    end
  end

  defp verify_death(attempt) do
    case attempt.pgid do
      pgid when is_integer(pgid) and pgid > 1 -> ProcessGroup.terminate(pgid)
      _ -> :dead_verified
    end
  end

  defp quarantine(attempt) do
    if attempt.workspace_id do
      _ = Workspaces.quarantine(attempt.workspace_id, Actor.system(), "death_unverified")
    end

    _ =
      Attempts.mark_lost(attempt.id, Actor.system(), %{
        inventory: :unconfirmed
      })

    :ok
  end

  defp release_if_idle(attempt) do
    still =
      Repo.all(
        from(a in Attempt,
          where:
            a.mission_id == ^attempt.mission_id and
              a.status in [
                "planned",
                "starting",
                "running",
                "checkpoint_requested",
                "terminating"
              ]
        )
      )

    if still == [] do
      GlobalScheduler.release_slot(attempt.mission_id)
    end
  end
end
