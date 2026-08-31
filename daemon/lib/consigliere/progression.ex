defmodule Consigliere.Progression do
  @moduledoc """
  Post-Attempt import and validation. Git and Project checks run outside the
  serialized SQLite writer. Safe to call repeatedly for one Attempt.
  """

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.AttemptResults
  alias Consigliere.AttemptResults.AttemptResult
  alias Consigliere.DatabaseWriter
  alias Consigliere.Git
  alias Consigliere.Gates.Gate
  alias Consigliere.Incidents.Incident
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Projects
  alias Consigliere.Projects.Project
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Workspaces.Workspace

  def progressable?(%Attempt{} = attempt) do
    case AttemptResults.by_attempt(attempt.id) do
      %AttemptResult{status: status}
      when status in ["reported", "death_verified", "commit_verified", "imported"] ->
        attempt.status in ["running", "checkpoint_requested"]

      _ ->
        false
    end
  end

  def progressable?(_), do: false

  def after_classify(%Attempt{} = attempt, opts \\ []) do
    cond do
      attempt.exit_classification == "protocol_failure" ->
        note_protocol_failure(attempt, "semantic completion without a committed SHA")
        {:ok, attempt}

      progressable?(attempt) ->
        run(attempt.id, opts)

      attempt.exit_classification == "completed" and
        attempt.status in ["running", "checkpoint_requested"] and not sha_present?(attempt) ->
        protocol_fail(attempt, "semantic completion without a committed SHA")

      true ->
        {:ok, attempt}
    end
  end

  def run(attempt_id, opts \\ []) do
    attempt = Repo.get!(Attempt, attempt_id)
    mission = Repo.get!(Mission, attempt.mission_id)
    result = AttemptResults.by_attempt(attempt.id)

    cond do
      mission.phase not in ["active"] ->
        {:ok, :skipped}

      attempt.status == "checkpointed" ->
        {:ok, :checkpointed}

      result == nil ->
        {:error, :result_missing}

      result.status == "failed" ->
        {:error, {:progression_failed, result.failure_code}}

      attempt.status == "completed" and result.status == "imported" ->
        Consigliere.Progression.Gates.finish(attempt, mission, opts)

      progressable?(attempt) or result.status in ["reported", "death_verified", "commit_verified"] ->
        do_run(attempt, mission, result, opts)

      true ->
        {:ok, :skipped}
    end
  end

  def maybe_progress(mission_id) do
    case latest_attempt(mission_id) do
      %Attempt{} = attempt -> run(attempt.id)
      _ -> {:ok, :none}
    end
  end

  def next_action(%Mission{} = mission) do
    attempt = latest_attempt(mission.id)

    cond do
      mission.phase == "ready_for_review" ->
        :review

      mission.phase != "active" ->
        :none

      match?(%Attempt{exit_classification: "protocol_failure"}, attempt) ->
        :protocol_failure

      progressable?(attempt) ->
        :import

      pending_gates?(mission) ->
        :validate

      true ->
        :none
    end
  end

  def next_action(_), do: :none

  defp do_run(attempt, mission, result, opts) do
    with :ok <- require_death(result, opts),
         :ok <- AttemptResults.bind_terminal_sequence(result),
         :ok <- mark_death(result),
         :ok <- verify_result(attempt, mission, result),
         :ok <- mark_commit_verified(result),
         {:ok, sha} <- import_result(attempt, mission, result),
         {:ok, imported} <- mark_imported(result, sha),
         {:ok, _} <- finalize_attempt(attempt, imported),
         :ok <- Attempts.release_scheduler_slot(attempt.id) do
      case imported.result_kind do
        "checkpoint" ->
          {:ok, :checkpointed}

        "completed" ->
          Consigliere.Progression.Gates.finish(
            Repo.get!(Attempt, attempt.id),
            Repo.get!(Mission, mission.id),
            opts
          )
      end
    else
      {:error, :death_not_verified} = error ->
        error

      {:error, :terminal_event_missing} = error ->
        error

      {:error, {:dispatch_slot_not_released, _}} = error ->
        error

      {:error, :result_import_persist_failed} ->
        retain_import_intent(attempt)

      {:error, reason} ->
        progression_fail(attempt, result, reason)
    end
  end

  defp retain_import_intent(attempt) do
    _ = note_progression_failure(attempt, "result_import_persist_failed")
    {:error, {:progression_failed, :result_import_persist_failed}}
  end

  defp protocol_fail(attempt, reason) do
    case Attempts.fail(attempt.id, Actor.system(), %{
           process_group: :dead_verified,
           exit_classification: "protocol_failure"
         }) do
      {:ok, _} ->
        note_protocol_failure(attempt, reason)

        case Attempts.release_scheduler_slot(attempt.id) do
          :ok -> {:error, :protocol_failure}
          {:error, slot_reason} -> {:error, slot_reason}
        end

      {:error, failure_reason} ->
        {:error, failure_reason}
    end
  end

  defp require_death(%AttemptResult{status: status}, _opts)
       when status in ["death_verified", "commit_verified", "imported"],
       do: :ok

  defp require_death(_result, opts) do
    if Keyword.get(opts, :process_group) == :dead_verified,
      do: :ok,
      else: {:error, :death_not_verified}
  end

  defp mark_death(%AttemptResult{status: "reported"} = result) do
    case AttemptResults.mark(result.id, "death_verified") do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :result_death_verification_persist_failed}
    end
  end

  defp mark_death(_result), do: :ok

  defp verify_result(attempt, mission, result) do
    workspace = workspace_of(attempt)
    project = mission.project_id && Repo.get(Project, mission.project_id)
    ancestry = result.parent_checkpoint_sha || result.base_sha

    cond do
      not match?(%Workspace{}, workspace) ->
        {:error, :workspace_missing}

      not match?(%Project{}, project) ->
        {:error, :project_missing}

      attempt.mission_id != result.mission_id ->
        {:error, :mission_identity_mismatch}

      mission.project_id != result.project_id ->
        {:error, :project_identity_mismatch}

      attempt.workspace_id != result.workspace_id ->
        {:error, :workspace_identity_mismatch}

      workspace.lease_id != result.workspace_generation ->
        {:error, :workspace_generation_mismatch}

      attempt.fencing_token != result.fencing_generation ->
        {:error, :fencing_generation_mismatch}

      mission.base_sha != result.base_sha ->
        {:error, :base_sha_mismatch}

      workspace.base_sha != result.base_sha ->
        {:error, :workspace_base_mismatch}

      workspace.parent_checkpoint_sha != result.parent_checkpoint_sha ->
        {:error, :parent_checkpoint_mismatch}

      not Git.valid_full_sha?(result.reported_sha) ->
        {:error, :result_sha_invalid}

      not Git.valid_full_sha?(ancestry) ->
        {:error, :ancestry_sha_invalid}

      true ->
        with :ok <- Git.tighten_workspace_permissions(workspace.path),
             :ok <-
               Projects.verify_workspace_identity(
                 project,
                 mission,
                 workspace,
                 result.reported_sha
               ),
             :ok <- Git.verify_ancestry(workspace.path, result.reported_sha, ancestry) do
          :ok
        else
          {:error, reason} -> {:error, map_git_failure(reason)}
        end
    end
  end

  defp mark_commit_verified(%AttemptResult{status: "death_verified"} = result) do
    case AttemptResults.mark(result.id, "commit_verified", %{verified_at: DateTime.utc_now()}) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :result_commit_verification_persist_failed}
    end
  end

  defp mark_commit_verified(_result), do: :ok

  defp import_result(attempt, mission, result) do
    workspace = workspace_of(attempt)
    mirror = mirror_of(mission)

    Git.import_result_sha(
      workspace.path,
      mirror,
      mission.project_id,
      attempt.id,
      result.reported_sha,
      result.parent_checkpoint_sha || result.base_sha
    )
  end

  defp mark_imported(result, sha) do
    ref = Git.result_ref(result.project_id, result.attempt_id)

    case AttemptResults.mark(
           result.id,
           "imported",
           %{imported_sha: sha, result_ref: ref, imported_at: DateTime.utc_now()}
         ) do
      {:ok, _} -> {:ok, Repo.get!(AttemptResult, result.id)}
      {:error, _} -> {:error, :result_import_persist_failed}
    end
  end

  defp finalize_attempt(attempt, result) do
    case result.result_kind do
      "checkpoint" ->
        Attempts.record_checkpointed(attempt.id, Actor.system(), %{
          process_group: :dead_verified,
          imported_sha: result.imported_sha,
          result_ref: result.result_ref
        })

      "completed" ->
        Attempts.complete(attempt.id, Actor.system(), %{
          process_group: :dead_verified,
          imported_sha: result.imported_sha,
          result_ref: result.result_ref
        })
    end
  end

  defp progression_fail(attempt, result, reason) do
    code = reason |> map_git_failure() |> to_string()
    _ = AttemptResults.fail(result.id, code, bounded_reason(reason))
    _ = note_progression_failure(attempt, code)

    failure_result =
      if attempt.status in ["running", "checkpoint_requested"] do
        Attempts.fail(attempt.id, Actor.system(), %{
          process_group: :dead_verified,
          exit_classification: code
        })
      else
        {:ok, attempt}
      end

    case failure_result do
      {:ok, _} ->
        case Attempts.release_scheduler_slot(attempt.id) do
          :ok -> {:error, {:progression_failed, code}}
          {:error, slot_reason} -> {:error, slot_reason}
        end

      {:error, failure_reason} ->
        {:error, failure_reason}
    end
  end

  defp note_progression_failure(attempt, code) do
    DatabaseWriter.transaction(fn ->
      Txn.insert!(
        Incident.changeset(%Incident{}, %{
          mission_id: attempt.mission_id,
          subject_type: "attempt",
          subject_id: attempt.id,
          severity: "error",
          reason: "post-attempt progression failed: #{String.slice(code, 0, 128)}"
        })
      )
    end)

    :ok
  end

  defp map_git_failure(:not_ancestor), do: :not_ancestor
  defp map_git_failure(:invalid_sha), do: :result_sha_invalid
  defp map_git_failure(:head_mismatch), do: :workspace_head_mismatch
  defp map_git_failure(:hooks_path_missing), do: :workspace_configuration_violation
  defp map_git_failure(:hooks_path_present), do: :workspace_configuration_violation
  defp map_git_failure(:credential_helper_present), do: :workspace_configuration_violation
  defp map_git_failure(:remotes_present), do: :workspace_configuration_violation
  defp map_git_failure(:alternates_present), do: :workspace_configuration_violation
  defp map_git_failure(:unsafe_permissions), do: :workspace_configuration_violation
  defp map_git_failure(:git_symlink), do: :workspace_configuration_violation
  defp map_git_failure(:shared_objects), do: :workspace_configuration_violation
  defp map_git_failure({:result_import_failed, _}), do: :result_import_failed
  defp map_git_failure(:result_ref_mismatch), do: :result_ref_mismatch
  defp map_git_failure(:result_death_verification_persist_failed), do: :result_persist_failed
  defp map_git_failure(:result_commit_verification_persist_failed), do: :result_persist_failed
  defp map_git_failure(:result_import_persist_failed), do: :result_persist_failed
  defp map_git_failure(reason) when is_atom(reason), do: reason
  defp map_git_failure(_reason), do: :progression_failed

  defp bounded_reason(reason), do: inspect(reason) |> String.slice(0, 512)

  def note_protocol_failure(attempt, reason) do
    DatabaseWriter.transaction(fn ->
      Txn.insert!(
        Incident.changeset(%Incident{}, %{
          mission_id: attempt.mission_id,
          subject_type: "attempt",
          subject_id: attempt.id,
          severity: "error",
          reason: reason
        })
      )
    end)

    :ok
  end

  defp sha_present?(%Attempt{reported_checkpoint_sha: sha})
       when is_binary(sha) and sha != "",
       do: true

  defp sha_present?(_), do: false

  defp pending_gates?(%Mission{current_checkpoint_sha: sha} = mission)
       when is_binary(sha) and sha != "" do
    types = Missions.required_gate_types(mission)

    Enum.any?(types, fn type ->
      not Repo.exists?(
        from(g in Gate,
          where:
            g.mission_id == ^mission.id and g.gate_type == ^type and g.status == "passed" and
              g.input_sha == ^sha
        )
      )
    end)
  end

  defp pending_gates?(_), do: false

  defp latest_attempt(mission_id) do
    Repo.one(
      from(a in Attempt,
        where: a.mission_id == ^mission_id,
        order_by: [desc: a.inserted_at],
        limit: 1
      )
    )
  end

  defp workspace_of(%Attempt{workspace_id: id}) when is_binary(id), do: Repo.get(Workspace, id)
  defp workspace_of(_), do: nil

  defp mirror_of(%Mission{project_id: id}) when is_binary(id) do
    case Repo.get(Project, id) do
      %Project{trusted_mirror_path: path} -> path
      _ -> Path.join(System.tmp_dir!(), "cs-missing-mirror")
    end
  end

  defp mirror_of(_), do: Path.join(System.tmp_dir!(), "cs-missing-mirror")
end
