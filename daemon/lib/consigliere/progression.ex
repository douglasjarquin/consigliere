defmodule Consigliere.Progression do
  @moduledoc """
  Post-Attempt import and validation. Git and Made run outside the
  serialized SQLite writer. Safe to call repeatedly for one Attempt.
  """

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Attempts
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Checkpoints
  alias Consigliere.DatabaseWriter
  alias Consigliere.Git
  alias Consigliere.Gates.Gate
  alias Consigliere.GlobalScheduler
  alias Consigliere.Incidents.Incident
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Projects.Project
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Workspaces.Workspace

  def progressable?(%Attempt{} = attempt) do
    sha_present?(attempt) and
      (attempt.status in ["running", "checkpoint_requested"] or
         (attempt.status == "completed" and not imported?(attempt)))
  end

  def progressable?(_), do: false

  def after_classify(%Attempt{} = attempt) do
    cond do
      attempt.exit_classification == "protocol_failure" ->
        note_protocol_failure(attempt, "semantic completion without a committed SHA")
        {:ok, attempt}

      progressable?(attempt) ->
        run(attempt.id)

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

    cond do
      mission.phase not in ["active"] ->
        {:ok, :skipped}

      attempt.status == "checkpointed" ->
        {:ok, :checkpointed}

      attempt.status == "completed" and imported?(attempt) ->
        Consigliere.Progression.Gates.finish(attempt, mission, opts)

      progressable?(attempt) ->
        do_run(attempt, mission, opts)

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

  defp do_run(attempt, mission, opts) do
    sha = attempt.reported_checkpoint_sha

    if not sha_present?(attempt) do
      protocol_fail(attempt, "semantic completion without a committed SHA")
    else
      workspace = workspace_of(attempt)
      mirror = mirror_of(mission)

      opts_import = [
        process_group: :dead_verified,
        workspace_path: workspace.path,
        mirror_path: mirror,
        sha: sha,
        base_sha: workspace.base_sha || mission.base_sha
      ]

      case attempt.status do
        "checkpoint_requested" ->
          case Checkpoints.import_after_death(attempt.id, opts_import) do
            {:ok, _} ->
              GlobalScheduler.release_slot(mission.id)
              {:ok, :checkpointed}

            {:error, reason} ->
              protocol_fail(attempt, "checkpoint import failed: #{inspect(reason)}")
          end

        _ ->
          case Git.import_sha(workspace.path, mirror, sha, workspace.base_sha || mission.base_sha) do
            {:ok, sha} ->
              _ =
                Attempts.complete(attempt.id, Actor.system(), %{
                  process_group: :dead_verified,
                  imported_sha: sha
                })

              GlobalScheduler.release_slot(mission.id)

              Consigliere.Progression.Gates.finish(
                Repo.get!(Attempt, attempt.id),
                Repo.get!(Mission, mission.id),
                opts
              )

            {:error, reason} ->
              protocol_fail(attempt, "checkpoint import failed: #{inspect(reason)}")
          end
      end
    end
  end

  defp protocol_fail(attempt, reason) do
    _ =
      Attempts.fail(attempt.id, Actor.system(), %{
        process_group: :dead_verified,
        exit_classification: "protocol_failure"
      })

    note_protocol_failure(attempt, reason)
    GlobalScheduler.release_slot(attempt.mission_id)
    {:error, :protocol_failure}
  end

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

  defp imported?(attempt) do
    case Repo.get(Mission, attempt.mission_id) do
      %Mission{current_checkpoint_sha: sha} ->
        sha_present?(attempt) and sha == attempt.reported_checkpoint_sha

      _ ->
        false
    end
  end

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
