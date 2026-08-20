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
  def grant_work_quietly(mission_id, actor \\ Consigliere.Actor.boss(), attrs \\ %{}) do
    Consigliere.Missions.Transitions.grant_work_authorization(mission_id, actor, attrs)
  end

  def stop_runtime! do
    stop_children(Consigliere.MissionDynamicSupervisor)
    stop_children(Consigliere.RunnerDynamicSupervisor)
    :ok
  end

  defp stop_children(sup) do
    case Process.whereis(sup) do
      nil ->
        :ok

      _ ->
        Enum.each(DynamicSupervisor.which_children(sup), fn
          {_, pid, _, _} when is_pid(pid) ->
            _ = DynamicSupervisor.terminate_child(sup, pid)

          _ ->
            :ok
        end)
    end
  end

  def reset_phase1_tables! do
    stop_runtime!()
    Repo.delete_all(Consigliere.DispatchOperations.DispatchOperation)
    Repo.update_all(Mission, set: [authorization_id: nil])
    Repo.delete_all(Decision)
    Repo.delete_all(Question)
    Repo.delete_all(Gate)
    Repo.delete_all(MissionBlocker)
    Repo.delete_all(MissionValidationLedger)
    Repo.delete_all(Incident)
    Repo.delete_all(HarnessEvent)
    Repo.delete_all(Consigliere.Capabilities.AttemptCapability)
    Repo.delete_all(Attempt)
    Repo.delete_all(Workspace)
    Repo.delete_all(Authorization)
    Repo.delete_all(Mission)
    Repo.delete_all(Consigliere.BossCursors.BossCursor)
    Repo.delete_all(Consigliere.Projects.Project)
    Repo.delete_all(Consigliere.CommandReceipts.CommandReceipt)
    Repo.delete_all(DomainEvent)
    Repo.delete_all(OutboxItem)
    :ok
  end

  def dummy_project! do
    {:ok, project} =
      Repo.insert(
        Consigliere.Projects.Project.changeset(%Consigliere.Projects.Project{}, %{
          name: "fixture",
          repository_url: "file:///tmp/cs-fix-#{System.unique_integer([:positive])}",
          default_branch: "main",
          trusted_mirror_path:
            Path.join(System.tmp_dir!(), "cs-nomirror-#{System.unique_integer([:positive])}")
        })
      )

    project
  end

  def mission_attrs(extra \\ %{}) do
    Map.merge(
      %{
        objective: "o",
        scope: "s",
        acceptance_criteria: "a",
        project_id: dummy_project!().id
      },
      extra
    )
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
