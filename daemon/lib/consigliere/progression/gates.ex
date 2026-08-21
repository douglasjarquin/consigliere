defmodule Consigliere.Progression.Gates do
  @moduledoc false

  import Ecto.Query

  alias Consigliere.Actor
  alias Consigliere.Gates
  alias Consigliere.Gates.Gate
  alias Consigliere.Made.Validate
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo
  alias Consigliere.Workspaces.Workspace

  def finish(attempt, mission, opts) do
    sha = mission.current_checkpoint_sha || attempt.reported_checkpoint_sha
    base = mission.base_sha || sha
    hash = policy_hash(mission)
    types = Missions.required_gate_types(mission)

    invalidate_stale(mission, sha, hash)

    Enum.each(types, fn type ->
      {:ok, gate} = ensure_gate(mission, type, sha, base, hash)
      run_gate(gate, attempt, opts)
    end)

    case Missions.mark_ready_for_review(mission.id, Actor.system()) do
      {:ok, ready} -> {:ok, ready}
      {:error, _} -> {:ok, Repo.get!(Mission, mission.id)}
    end
  end

  defp run_gate(%Gate{status: status} = gate, _attempt, _opts)
       when status in ["passed", "needs_decision", "failed_terminal", "canceled"] do
    gate
  end

  defp run_gate(gate, attempt, opts) do
    gate =
      case gate.status do
        "pending" ->
          {:ok, started} =
            Gates.start(gate.id, Actor.system(), %{managed_run_id: "made-#{gate.id}"})

          started

        _ ->
          gate
      end

    workspace = workspace_of(attempt)

    Validate.run(gate, attempt,
      workspace: workspace && workspace.path,
      forced_outcome: Keyword.get(opts, :forced_outcome)
    )
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

  defp workspace_of(%{workspace_id: id}) when is_binary(id), do: Repo.get(Workspace, id)
  defp workspace_of(_), do: nil

  defp policy_hash(%Mission{validation_policy: policy}) do
    encoded = JSON.encode!(policy || %{})
    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end
end
