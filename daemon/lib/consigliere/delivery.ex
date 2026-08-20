defmodule Consigliere.Delivery do
  @moduledoc """
  Exact-SHA delivery. Privileged push happens from the trusted mirror
  with a daemon-owned remote URL. Merge is a server-side expected-head
  SHA compare-and-swap. Git and GitHub calls never run inside a
  DatabaseWriter transaction.
  """

  alias Consigliere.Actor
  alias Consigliere.Git
  alias Consigliere.GitHub.Fake
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo

  def prepare(mission_id, spec) do
    sha = Map.fetch!(spec, :sha)
    github = Map.fetch!(spec, :github)
    adapter = Map.get(spec, :adapter, Fake)

    with {:ok, ^sha} <-
           Git.push_sha(spec.mirror, spec.remote_url, sha, spec.ref),
         :success <- adapter.ci_status(github, sha),
         pr <- adapter.upsert_pr(github, spec.ref, sha),
         {:ok, mission} <-
           Missions.await_integration_authorization(mission_id, Actor.system(), %{
             delivery_sha: sha
           }) do
      {:ok, %{mission: mission, pr: pr}}
    else
      status when status in [:unknown, :pending, :failure] ->
        {:error, {:ci_not_success, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def merge(mission_id, spec) do
    github = Map.fetch!(spec, :github)
    adapter = Map.get(spec, :adapter, Fake)
    pr = Map.fetch!(spec, :pr)
    mission = Repo.get!(Mission, mission_id)
    expected = mission.current_delivery_sha

    case adapter.merge(github, pr, expected) do
      {:ok, merged_sha} ->
        Missions.complete_integration(mission_id, Actor.system(), %{merged_sha: merged_sha})

      {:error, {:head_moved, _}} ->
        Missions.detect_integration_race(mission_id, Actor.system(), "head moved")
    end
  end
end
