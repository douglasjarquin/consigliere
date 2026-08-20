defmodule Consigliere.Reconciler.Pass do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.AttemptStates
  alias Consigliere.Attempts
  alias Consigliere.DatabaseWriter
  alias Consigliere.GlobalScheduler
  alias Consigliere.HarnessEvents.HarnessEvent
  alias Consigliere.Incidents.Incident
  alias Consigliere.Missions.Mission
  alias Consigliere.ProcessGroup
  alias Consigliere.Repo
  alias Consigliere.Txn

  def apply_live(manifest, attempt, runner_live?) do
    cond do
      runner_live? ->
        {:skipped, attempt.id}

      AttemptStates.terminal?(attempt.status) ->
        reap_live(manifest, attempt)

      process_group_alive?(manifest["pgid"]) ->
        incident(attempt, "orphaned live process group; adopt-and-kill")
        finalize_dead(attempt, adopt_kill(manifest))

      true ->
        finalize_dead(attempt, :dead_verified)
    end
  end

  def apply_terminal_manifest(manifest, attempt, runner_live?) do
    cond do
      AttemptStates.terminal?(attempt.status) ->
        {:skipped, attempt.id}

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

      valid_pgid?(attempt.pgid) and process_group_alive?(attempt.pgid) ->
        incident(attempt, "occupying Attempt has no manifest and a live process group")
        finalize_dead(attempt, adopt_kill(%{"pgid" => attempt.pgid}))

      valid_pgid?(attempt.pgid) ->
        finalize_dead(attempt, :dead_verified)

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
        checkpoint_imported?(attempt) ->
          Attempts.record_checkpointed(attempt.id, Actor.system(), %{
            imported_sha: attempt.reported_checkpoint_sha,
            process_group: :dead_verified
          })

          {:checkpointed, attempt.id}

        inventory != :dead_verified ->
          Attempts.mark_lost(attempt.id, Actor.system(), %{inventory: inventory})
          {:quarantined, attempt.id}

        completed_intent?(attempt) ->
          complete_or_lost(attempt)

        failed_intent?(attempt) ->
          _ =
            Attempts.fail(attempt.id, Actor.system(), %{
              process_group: :dead_verified,
              exit_classification: attempt.exit_classification || "failed"
            })

          {:failed, attempt.id}

        true ->
          Attempts.mark_lost(attempt.id, Actor.system(), %{inventory: inventory})
          {:lost, attempt.id}
      end

    _ = GlobalScheduler.release_slot(attempt.mission_id)
    result
  end

  defp complete_or_lost(attempt) do
    case Attempts.complete(attempt.id, Actor.system(), %{process_group: :dead_verified}) do
      {:ok, _} ->
        {:completed, attempt.id}

      {:error, _} ->
        Attempts.mark_lost(attempt.id, Actor.system(), %{inventory: :dead_verified})
        {:lost, attempt.id}
    end
  end

  defp completed_intent?(attempt) do
    attempt.exit_classification == "completed" or
      last_harness_type(attempt.id) in ["session.completed", "turn.completed"]
  end

  defp failed_intent?(attempt) do
    attempt.exit_classification not in [nil, "completed"] or
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

  defp checkpoint_imported?(attempt) do
    attempt.status == "checkpoint_requested" and
      is_binary(attempt.reported_checkpoint_sha) and
      case Repo.get(Mission, attempt.mission_id) do
        %Mission{current_checkpoint_sha: sha} -> sha == attempt.reported_checkpoint_sha
        _ -> false
      end
  end

  defp process_group_alive?(pgid) when is_integer(pgid) and pgid > 1 do
    ProcessGroup.alive?(pgid)
  end

  defp process_group_alive?(_), do: true

  defp valid_pgid?(pgid) when is_integer(pgid) and pgid > 1, do: true
  defp valid_pgid?(_), do: false

  defp adopt_kill(%{"pgid" => pgid}) do
    if ProcessGroup.terminate(pgid) == :dead_verified, do: :dead_verified, else: :unconfirmed
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
