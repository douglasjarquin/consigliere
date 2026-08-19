defmodule Consigliere.Workspaces.Transitions do
  @moduledoc false

  alias Consigliere.DatabaseWriter
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Workspaces.Workspace
  alias Consigliere.Incidents.Incident

  def create(mission_id, actor, attrs) do
    DatabaseWriter.transaction(fn -> create_txn(mission_id, actor, attrs) end)
  end

  def create_txn(mission_id, actor, attrs) do
    Txn.require_principal(actor, ["boss", "daemon"])

    Txn.insert!(
      Workspace.changeset(
        %Workspace{},
        Map.merge(
          %{
            mission_id: mission_id,
            status: "active",
            lease_id: Map.get(attrs, :lease_id, "lease-#{Txn.mint_fencing_token()}"),
            fencing_token: Map.get(attrs, :fencing_token, Txn.mint_fencing_token())
          },
          Map.take(attrs, [:path, :lease_id, :fencing_token, :status])
        )
      )
    )
  end

  def mark_daemon_exclusive(workspace_id, actor, opts) do
    DatabaseWriter.transaction(fn -> mark_daemon_exclusive_txn(workspace_id, actor, opts) end)
  end

  def mark_daemon_exclusive_txn(workspace_id, actor, opts) do
    Txn.require_principal(actor, ["boss", "daemon"])
    workspace = fetch!(workspace_id)

    if Map.get(opts, :process_group) != :dead_verified do
      Txn.illegal(workspace.status, "daemon_exclusive", :death_not_verified)
    end

    unless workspace.status == "active" do
      Txn.illegal(workspace.status, "daemon_exclusive", :wrong_status)
    end

    Txn.update!(Workspace.changeset(workspace, %{status: "daemon_exclusive"}))
  end

  def quarantine(workspace_id, actor, reason) do
    DatabaseWriter.transaction(fn -> quarantine_txn(workspace_id, actor, reason) end)
  end

  def quarantine_txn(workspace_id, actor, reason) do
    Txn.require_principal(actor, ["boss", "daemon"])
    workspace = fetch!(workspace_id)

    if workspace.status == "released" do
      Txn.illegal(workspace.status, "quarantined", :already_released)
    end

    Txn.insert!(
      Incident.changeset(%Incident{}, %{
        mission_id: workspace.mission_id,
        subject_type: "workspace",
        subject_id: workspace.id,
        severity: "warning",
        reason: reason
      })
    )

    Txn.update!(
      Workspace.changeset(workspace, %{status: "quarantined", quarantine_reason: reason})
    )
  end

  def release(workspace_id, actor) do
    DatabaseWriter.transaction(fn -> release_txn(workspace_id, actor) end)
  end

  def release_txn(workspace_id, actor) do
    Txn.require_principal(actor, ["boss", "daemon"])
    workspace = fetch!(workspace_id)

    unless workspace.status == "daemon_exclusive" do
      Txn.illegal(workspace.status, "released", :not_daemon_exclusive)
    end

    Txn.update!(Workspace.changeset(workspace, %{status: "released"}))
  end

  defp fetch!(id) do
    case Repo.get(Workspace, id) do
      nil -> Txn.illegal(nil, nil, :not_found)
      workspace -> workspace
    end
  end
end
