defmodule Consigliere.Progression.Gates do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Gates
  alias Consigliere.Gates.Gate
  alias Consigliere.AttemptResults
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.ProjectVerifications
  alias Consigliere.Projects.Project
  alias Consigliere.Repo

  def finish(attempt, mission, opts) do
    sha = mission.current_checkpoint_sha || attempt.imported_sha
    base = mission.base_sha || sha
    hash = policy_hash(mission)
    types = Missions.required_gate_types(mission)
    result = AttemptResults.by_attempt(attempt.id)

    case result do
      %Consigliere.AttemptResults.AttemptResult{
        result_kind: "completed",
        imported_sha: ^sha
      } ->
        invalidate_stale(mission, sha, hash)

        Enum.each(types, fn type ->
          {:ok, gate} = ensure_gate(mission, type, sha, base, hash)
          run_gate(gate, attempt, mission, result, type, opts)
        end)

        if all_passed?(mission.id, sha) do
          case Missions.mark_ready_for_review(mission.id, Actor.system()) do
            {:ok, ready} -> {:ok, ready}
            {:error, _} -> {:ok, Repo.get!(Mission, mission.id)}
          end
        else
          {:error, :verification_failed}
        end

      _ ->
        {:error, :result_not_imported}
    end
  end

  defp run_gate(%Gate{status: status} = gate, _attempt, _mission, _result, _type, _opts)
       when status in [
              "passed",
              "needs_decision",
              "failed_terminal",
              "failed_retryable",
              "canceled"
            ],
       do: gate

  defp run_gate(%Gate{} = gate, attempt, mission, result, type, opts) do
    gate =
      case gate.status do
        "pending" ->
          {:ok, started} =
            Gates.start(gate.id, Actor.system(), %{managed_run_id: "local-#{gate.id}"})

          started

        _ ->
          gate
      end

    case ProjectVerifications.run(attempt, mission, result, type, opts) do
      {:ok, :passed, runs} ->
        output_sha = runs |> List.last() |> Map.get(:output_digest)
        {:ok, passed} = Gates.pass(gate.id, Actor.system(), %{output_sha: output_sha})
        passed

      {:error, runs} when is_list(runs) ->
        outcome = runs |> List.last() |> Map.get(:outcome)

        case outcome do
          "canceled" ->
            {:ok, canceled} = Gates.cancel(gate.id, Actor.system())
            canceled

          "infrastructure_error" ->
            {:ok, failed} = Gates.record_infrastructure_error(gate.id, Actor.system())
            failed

          _ ->
            {:ok, failed} =
              Gates.fail_retryable(gate.id, Actor.system(), %{
                finding_fingerprint: "verification-#{gate.id}",
                findings: []
              })

            Map.get(failed, :gate, failed)
        end

      {:error, reason} ->
        _ = Gates.record_infrastructure_error(gate.id, Actor.system())
        {:error, reason}
    end
  end

  defp all_passed?(mission_id, sha) do
    types = Missions.required_gate_types(Repo.get!(Mission, mission_id))

    Enum.all?(types, fn type ->
      Repo.exists?(
        from(g in Gate,
          where:
            g.mission_id == ^mission_id and g.gate_type == ^type and g.status == "passed" and
              g.input_sha == ^sha
        )
      )
    end)
  end

  defp ensure_gate(mission, type, sha, base, hash) do
    case Repo.get_by(Gate,
           mission_id: mission.id,
           gate_type: type,
           input_sha: sha,
           base_sha: base,
           policy_hash: hash
         ) do
      %Gate{status: "invalidated"} ->
        Gates.create(mission.id, Actor.system(), %{
          gate_type: type,
          input_sha: sha,
          base_sha: base,
          policy_hash: hash
        })

      %Gate{} = gate ->
        {:ok, gate}

      nil ->
        Gates.create(mission.id, Actor.system(), %{
          gate_type: type,
          input_sha: sha,
          base_sha: base,
          policy_hash: hash
        })
    end
  end

  defp invalidate_stale(mission, sha, hash) do
    from(g in Gate,
      where:
        g.mission_id == ^mission.id and
          (g.input_sha != ^sha or g.policy_hash != ^hash) and
          g.status in ["pending", "running", "passed", "needs_decision"]
    )
    |> Repo.all()
    |> Enum.each(fn gate -> Gates.invalidate(gate.id, Actor.system()) end)
  end

  defp policy_hash(%Mission{} = mission) do
    project = mission.project_id && Repo.get(Project, mission.project_id)

    project_policy =
      if match?(%Project{}, project) and is_map(project.validation_policy),
        do: project.validation_policy,
        else: %{}

    mission_policy =
      if is_map(mission.validation_policy), do: mission.validation_policy, else: %{}

    policy = Map.merge(project_policy, mission_policy)

    encoded = JSON.encode!(policy)
    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end
end
