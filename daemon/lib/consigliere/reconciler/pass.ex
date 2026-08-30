defmodule Consigliere.Reconciler.Pass do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.AttemptResults
  alias Consigliere.AttemptStates
  alias Consigliere.Attempts
  alias Consigliere.DatabaseWriter
  alias Consigliere.DispatchOperations
  alias Consigliere.HarnessEvents.HarnessEvent
  alias Consigliere.Incidents.Incident
  alias Consigliere.ProcessGroup
  alias Consigliere.Repo
  alias Consigliere.Runtime.Inventory
  alias Consigliere.Txn

  def apply_live(manifest, attempt, runner_live?) do
    liveness = Inventory.liveness(manifest)

    cond do
      runner_live? ->
        {:skipped, attempt.id}

      liveness in [:identity_mismatch, :permission_unknown, :observation_failed] ->
        incident(attempt, "runner inventory liveness #{liveness}")

        if AttemptStates.terminal?(attempt.status) do
          {:skipped, attempt.id}
        else
          finalize_dead(attempt, :unconfirmed)
        end

      AttemptStates.terminal?(attempt.status) ->
        reap_live(manifest, attempt)

      liveness == :verified ->
        incident(attempt, "orphaned live process group; adopt-and-kill")
        finalize_dead(attempt, adopt_kill(manifest))

      true ->
        finalize_dead(attempt, :dead_verified)
    end
  end

  def apply_terminal_manifest(manifest, attempt, runner_live?) do
    cond do
      AttemptStates.terminal?(attempt.status) ->
        case release_dispatch_slot_result(attempt, manifest["state"]) do
          :ok -> {:skipped, attempt.id}
          {:error, reason} -> {:error, {attempt.id, reason}}
        end

      runner_live? ->
        {:skipped, attempt.id}

      manifest["state"] == "dead_unverified" ->
        finalize_dead(attempt, :unconfirmed)

      true ->
        finalize_dead(attempt, :dead_verified)
    end
  end

  def without_manifest(attempt, runner_live?) do
    cond do
      runner_live? ->
        {:skipped, attempt.id}

      AttemptStates.recoverable?(attempt.status) ->
        {:skipped, attempt.id}

      valid_pgid?(attempt.pgid) ->
        case ProcessGroup.liveness(attempt.pgid) do
          :absent ->
            finalize_dead(attempt, :dead_verified)

          liveness ->
            incident(
              attempt,
              "occupying Attempt has no manifest; process group liveness #{liveness} is not signalable"
            )

            finalize_dead(attempt, :unconfirmed)
        end

      true ->
        finalize_dead(attempt, :unconfirmed)
    end
  end

  def mismatch(path, kind) do
    record_incident(%{severity: "warning", reason: "runner inventory #{kind}: #{path}"})
    {:incident, kind}
  end

  def corrupt(path) do
    record_incident(%{severity: "warning", reason: "corrupt runner manifest: #{path}"})
    {:incident, :corrupt}
  end

  defp reap_live(manifest, attempt) do
    _ = adopt_kill(manifest)
    incident(attempt, "live runner inventory for terminal Attempt")
    {:reaped, attempt.id}
  end

  defp finalize_dead(attempt, inventory) do
    result =
      cond do
        inventory != :dead_verified ->
          case Attempts.mark_lost(attempt.id, Actor.system(), %{inventory: inventory}) do
            {:ok, _} -> {:ok, {:quarantined, attempt.id}}
            {:error, reason} -> {:error, reason}
          end

        imported_result?(attempt) ->
          complete_or_lost(attempt)

        completed_intent?(attempt) ->
          complete_or_lost(attempt)

        failed_intent?(attempt) ->
          case Attempts.fail(attempt.id, Actor.system(), %{
                 process_group: :dead_verified,
                 exit_classification: attempt.exit_classification || "failed"
               }) do
            {:ok, _} -> {:ok, {:failed, attempt.id}}
            {:error, reason} -> {:error, reason}
          end

        true ->
          case Attempts.mark_lost(attempt.id, Actor.system(), %{inventory: inventory}) do
            {:ok, _} -> {:ok, {:lost, attempt.id}}
            {:error, reason} -> {:error, reason}
          end
      end

    case result do
      {:error, reason} ->
        {:error, reason}

      {:ok, value} when inventory == :dead_verified ->
        case Attempts.release_scheduler_slot(attempt.id) do
          :ok -> value
          {:error, reason} -> {:error, reason}
        end

      {:ok, value} ->
        value
    end
  end

  defp release_dispatch_slot(attempt) do
    with {:ok, _} <- DispatchOperations.release_slot(attempt.id),
         :ok <- Attempts.release_scheduler_slot(attempt.id) do
      :ok
    end
  end

  defp release_dispatch_slot_result(attempt, "dead_verified"),
    do: release_dispatch_slot(attempt)

  defp release_dispatch_slot_result(_attempt, _state), do: :ok

  defp complete_or_lost(attempt) do
    case Consigliere.Progression.after_classify(attempt, process_group: :dead_verified) do
      {:ok, %Consigliere.Attempts.Attempt{status: "completed"}} ->
        {:completed, attempt.id}

      {:ok, %Consigliere.Attempts.Attempt{status: "checkpointed"}} ->
        {:checkpointed, attempt.id}

      {:ok, %Consigliere.Attempts.Attempt{status: "failed"}} ->
        {:failed, attempt.id}

      {:ok, :checkpointed} ->
        {:checkpointed, attempt.id}

      {:ok, _} ->
        {:completed, attempt.id}

      {:error, :protocol_failure} ->
        {:failed, attempt.id}

      {:error, {:progression_failed, _reason}} ->
        {:failed, attempt.id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp completed_intent?(attempt) do
    attempt.exit_classification == "completed" or
      last_harness_type(attempt.id) in ["session.completed", "turn.completed"]
  end

  defp failed_intent?(attempt) do
    attempt.exit_classification not in [nil, "completed", "completion_reported"] or
      last_harness_type(attempt.id) == "session.failed"
  end

  defp last_harness_type(attempt_id) do
    Repo.one(
      from(e in HarnessEvent,
        where: e.attempt_id == ^attempt_id,
        order_by: [desc: e.native_sequence],
        limit: 1,
        select: e.type
      )
    )
  end

  defp imported_result?(attempt) do
    case AttemptResults.by_attempt(attempt.id) do
      %AttemptResults.AttemptResult{status: "imported"} -> true
      _ -> false
    end
  end

  defp valid_pgid?(pgid) when is_integer(pgid) and pgid > 1, do: true
  defp valid_pgid?(_), do: false

  defp adopt_kill(%{"pgid" => pgid} = manifest) do
    if Inventory.liveness(manifest) == :verified and
         ProcessGroup.terminate(pgid) == :dead_verified do
      :dead_verified
    else
      :unconfirmed
    end
  end

  defp adopt_kill(_), do: :unconfirmed

  defp incident(attempt, reason) do
    record_incident(%{
      mission_id: attempt.mission_id,
      subject_type: "attempt",
      subject_id: attempt.id,
      severity: "warning",
      reason: reason
    })
  end

  defp record_incident(attrs) do
    DatabaseWriter.transaction(fn ->
      Txn.insert!(Incident.changeset(%Incident{}, attrs))
    end)
  end
end
