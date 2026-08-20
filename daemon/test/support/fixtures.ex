defmodule Consigliere.Fixtures do
  import Ecto.Query

  alias Consigliere.Repo
  alias Consigliere.Missions.Mission
  alias Consigliere.Workspaces.Workspace
  alias Consigliere.Attempts.Attempt
  alias Consigliere.Questions.Question
  alias Consigliere.Gates.Gate
  alias Consigliere.MissionBlockers.MissionBlocker
  alias Consigliere.MissionValidationLedgers.MissionValidationLedger
  alias Consigliere.Authorizations.Authorization
  alias Consigliere.Incidents.Incident
  alias Consigliere.Decisions.Decision
  alias Consigliere.DomainEvents.DomainEvent
  alias Consigliere.OutboxItems.OutboxItem
  alias Consigliere.HarnessEvents.HarnessEvent

  # FK-safe delete order: children before parents, since none of these
  # tests run inside an Ecto Sandbox transaction (matching this project's
  # existing non-sandboxed test style) -- leftover rows from one test file
  # otherwise accumulate and break any other file's blanket table cleanup.
  def reset_phase1_tables! do
    Repo.update_all(Mission, set: [authorization_id: nil])
    Repo.delete_all(Decision)
    Repo.delete_all(Question)
    Repo.delete_all(Gate)
    Repo.delete_all(MissionBlocker)
    Repo.delete_all(MissionValidationLedger)
    Repo.delete_all(Incident)
    Repo.delete_all(HarnessEvent)
    Repo.delete_all(Attempt)
    Repo.delete_all(Workspace)
    Repo.delete_all(Authorization)
    Repo.delete_all(Mission)
    Repo.delete_all(DomainEvent)
    Repo.delete_all(OutboxItem)
    :ok
  end

  def mission!(attrs \\ %{}) do
    defaults = %{objective: "o", scope: "s", acceptance_criteria: "a", phase: "draft"}
    {:ok, mission} = Repo.insert(Mission.changeset(%Mission{}, Map.merge(defaults, attrs)))
    mission
  end

  def workspace!(mission, attrs \\ %{}) do
    defaults = %{
      mission_id: mission.id,
      path: "/tmp/workspace-#{System.unique_integer([:positive])}",
      lease_id: "lease-#{System.unique_integer([:positive])}",
      fencing_token: "fence-#{System.unique_integer([:positive])}",
      status: "active"
    }

    {:ok, workspace} = Repo.insert(Workspace.changeset(%Workspace{}, Map.merge(defaults, attrs)))
    workspace
  end

  def attempt!(mission, attrs \\ %{}) do
    defaults = %{
      mission_id: mission.id,
      role: "soldier",
      harness: "claude",
      status: "planned",
      fencing_token: "fence-#{System.unique_integer([:positive])}"
    }

    {:ok, attempt} = Repo.insert(Attempt.changeset(%Attempt{}, Map.merge(defaults, attrs)))
    attempt
  end

  def events(subject_id) do
    DomainEvent
    |> where([e], e.subject_id == ^subject_id)
    |> order_by(:id)
    |> Repo.all()
  end

  def event_types(subject_id) do
    Enum.map(events(subject_id), & &1.type)
  end
end
