defmodule Consigliere.AttemptResults do
  @moduledoc """
  Durable, one-per-Attempt result reports and progression checkpoints.

  The report is captured by the writer, while Git import and Project
  verification happen in `Consigliere.Progression` outside writer
  transactions. Result rows make those external stages restartable without
  trusting a workspace marker or a process exit code.
  """

  import Ecto.Query

  alias Consigliere.AttemptResults.AttemptResult
  alias Consigliere.Attempts.Attempt
  alias Consigliere.DatabaseWriter
  alias Consigliere.HarnessEvents.HarnessEvent
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Workspaces.Workspace

  @result_fields ~w(mission_id project_id workspace_id workspace_generation base_sha
                    parent_checkpoint_sha fencing_generation terminal_sequence result_sha
                    result_kind)

  def by_attempt(attempt_id), do: Repo.get_by(AttemptResult, attempt_id: attempt_id)

  def capture_txn(%Attempt{} = attempt, _actor, attrs, kind, strict? \\ true) do
    mission = Repo.get(Mission, attempt.mission_id) || Txn.illegal(nil, nil, :mission_not_found)

    workspace =
      Repo.get(Workspace, attempt.workspace_id) || Txn.illegal(nil, nil, :workspace_not_found)

    report = normalize_report!(attempt, mission, workspace, attrs, kind, strict?)

    case by_attempt(attempt.id) do
      %AttemptResult{} = result ->
        if same_report?(result, report),
          do: result,
          else: Txn.illegal(attempt.status, kind, :result_conflict)

      nil ->
        result =
          Txn.insert!(
            AttemptResult.changeset(
              %AttemptResult{},
              Map.merge(report, %{attempt_id: attempt.id, status: "reported"})
            )
          )

        Txn.append_event!("attempt.result_reported", "attempt", attempt.id, %{
          result_kind: result.result_kind,
          reported_sha: result.reported_sha,
          accepted_terminal_sequence: result.accepted_terminal_sequence
        })

        result
    end
  end

  def mark(id, status, attrs \\ %{}) do
    Consigliere.DatabaseWriter.transaction(fn -> mark_txn(id, status, attrs) end)
  end

  def mark_txn(id, status, attrs \\ %{}) do
    unless status in AttemptResult.statuses(), do: Txn.illegal("result", status, :status_invalid)

    result = Repo.get!(AttemptResult, id)

    if result.status == status or not status_can_advance?(result.status, status) do
      result
    else
      fields =
        %{status: status}
        |> maybe_put(:failure_code, attrs[:failure_code] || attrs["failure_code"])
        |> maybe_put(:failure_detail, attrs[:failure_detail] || attrs["failure_detail"])
        |> maybe_put(:imported_sha, attrs[:imported_sha] || attrs["imported_sha"])
        |> maybe_put(:result_ref, attrs[:result_ref] || attrs["result_ref"])
        |> maybe_put(:verified_at, attrs[:verified_at] || attrs["verified_at"])
        |> maybe_put(:imported_at, attrs[:imported_at] || attrs["imported_at"])

      Txn.update!(AttemptResult.changeset(result, fields))
    end
  end

  def fail(id, code, detail \\ nil) do
    Consigliere.DatabaseWriter.transaction(fn ->
      mark_txn(id, "failed", %{failure_code: to_string(code), failure_detail: detail})
    end)
  end

  def report_fields, do: @result_fields

  def bind_terminal_sequence(%AttemptResult{result_kind: "completed"} = result) do
    sequence =
      Repo.one(
        from(e in HarnessEvent,
          where: e.attempt_id == ^result.attempt_id and e.type == "session.completed",
          order_by: [desc: e.native_sequence],
          limit: 1,
          select: e.native_sequence
        )
      )

    if is_integer(sequence) and sequence > 0 do
      case DatabaseWriter.transaction(fn ->
             current = Repo.get!(AttemptResult, result.id)

             if current.accepted_terminal_sequence == sequence do
               current
             else
               Txn.update!(
                 AttemptResult.changeset(current, %{accepted_terminal_sequence: sequence})
               )
             end
           end) do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :terminal_sequence_persist_failed}
      end
    else
      {:error, :terminal_event_missing}
    end
  end

  def bind_terminal_sequence(%AttemptResult{}), do: :ok

  defp normalize_report!(attempt, mission, workspace, attrs, kind, strict?) do
    result_sha = value(attrs, :result_sha) || value(attrs, :reported_checkpoint_sha)
    result_kind = value(attrs, :result_kind) || kind
    terminal_sequence = value(attrs, :terminal_sequence)
    deferred_terminal? = terminal_sequence == "latest" and result_kind == "completed"

    expected = %{
      mission_id: mission.id,
      project_id: mission.project_id,
      workspace_id: workspace.id,
      workspace_generation: workspace.lease_id,
      base_sha: workspace.base_sha || mission.base_sha,
      parent_checkpoint_sha: workspace.parent_checkpoint_sha,
      fencing_generation: attempt.fencing_token
    }

    reported = %{
      mission_id: value(attrs, :mission_id) || expected.mission_id,
      project_id: value(attrs, :project_id) || expected.project_id,
      workspace_id: value(attrs, :workspace_id) || expected.workspace_id,
      workspace_generation: value(attrs, :workspace_generation) || expected.workspace_generation,
      base_sha: value(attrs, :base_sha) || expected.base_sha,
      parent_checkpoint_sha:
        value(attrs, :parent_checkpoint_sha) || expected.parent_checkpoint_sha,
      fencing_generation: value(attrs, :fencing_generation) || expected.fencing_generation,
      accepted_terminal_sequence: resolve_terminal_sequence(terminal_sequence, attempt),
      reported_sha: result_sha,
      result_kind: result_kind
    }

    cond do
      strict? and
          Enum.any?(@result_fields, &(is_nil(value(attrs, &1)) and &1 != "parent_checkpoint_sha")) ->
        Txn.illegal(attempt.status, kind, :result_identity_required)

      strict? and not is_nil(expected.parent_checkpoint_sha) and
          is_nil(value(attrs, :parent_checkpoint_sha)) ->
        Txn.illegal(attempt.status, kind, :result_identity_required)

      not is_binary(reported.reported_sha) or
          not Consigliere.Git.valid_full_sha?(reported.reported_sha) ->
        Txn.illegal(attempt.status, kind, :result_sha_invalid)

      reported.result_kind not in AttemptResult.kinds() ->
        Txn.illegal(attempt.status, kind, :result_kind_invalid)

      reported.result_kind != kind ->
        Txn.illegal(attempt.status, kind, :result_kind_mismatch)

      not identity_matches?(reported, expected) ->
        Txn.illegal(attempt.status, kind, :result_identity_mismatch)

      not Consigliere.Git.valid_full_sha?(reported.base_sha) ->
        Txn.illegal(attempt.status, kind, :base_sha_invalid)

      not is_nil(reported.parent_checkpoint_sha) and
          not Consigliere.Git.valid_full_sha?(reported.parent_checkpoint_sha) ->
        Txn.illegal(attempt.status, kind, :parent_checkpoint_sha_invalid)

      not is_integer(reported.accepted_terminal_sequence) or
          reported.accepted_terminal_sequence < 1 ->
        Txn.illegal(attempt.status, kind, :terminal_sequence_invalid)

      is_integer(attempt.last_native_sequence) and
          reported.accepted_terminal_sequence > attempt.last_native_sequence ->
        Txn.illegal(attempt.status, kind, :terminal_sequence_unaccepted)

      strict? and not deferred_terminal? and
          not accepted_event?(
            attempt.id,
            reported.result_kind,
            reported.accepted_terminal_sequence
          ) ->
        Txn.illegal(attempt.status, kind, :terminal_event_missing)

      true ->
        reported
    end
  end

  defp identity_matches?(reported, expected) do
    Enum.all?(
      [
        :mission_id,
        :project_id,
        :workspace_id,
        :workspace_generation,
        :base_sha,
        :fencing_generation
      ],
      fn key -> Map.get(reported, key) == Map.get(expected, key) end
    ) and
      Map.get(reported, :parent_checkpoint_sha) == Map.get(expected, :parent_checkpoint_sha)
  end

  defp accepted_event?(attempt_id, "completed", sequence) do
    Repo.exists?(
      from(e in HarnessEvent,
        where:
          e.attempt_id == ^attempt_id and e.native_sequence == ^sequence and
            e.type == "session.completed"
      )
    )
  end

  defp accepted_event?(attempt_id, "checkpoint", sequence) do
    Repo.exists?(
      from(e in HarnessEvent,
        where:
          e.attempt_id == ^attempt_id and e.native_sequence == ^sequence and
            e.type in ["checkpoint.created", "progress.reported", "turn.completed"]
      )
    )
  end

  defp same_report?(result, report) do
    Enum.all?(@result_fields, fn key ->
      atom = report_field(key)
      Map.get(result, atom) == Map.get(report, atom)
    end)
  end

  defp report_field("result_sha"), do: :reported_sha
  defp report_field("terminal_sequence"), do: :accepted_terminal_sequence
  defp report_field(key), do: String.to_atom(key)

  defp value(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp value(attrs, key) when is_binary(key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  defp resolve_terminal_sequence("latest", attempt), do: attempt.last_native_sequence || 1
  defp resolve_terminal_sequence(nil, attempt), do: attempt.last_native_sequence || 1
  defp resolve_terminal_sequence(sequence, _attempt), do: sequence

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp status_can_advance?(current, next) do
    current_rank = status_rank(current)
    next_rank = status_rank(next)

    current != "imported" and current != "failed" and next_rank > current_rank
  end

  defp status_rank("reported"), do: 1
  defp status_rank("death_verified"), do: 2
  defp status_rank("commit_verified"), do: 3
  defp status_rank("imported"), do: 4
  defp status_rank("failed"), do: 5
  defp status_rank(_), do: 0
end
