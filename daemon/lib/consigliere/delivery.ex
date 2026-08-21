defmodule Consigliere.Delivery do
  @moduledoc """
  Exact-SHA delivery. Privileged push happens from the trusted mirror
  with a daemon-owned remote URL. Merge is a server-side expected-head
  SHA compare-and-swap. Git and GitHub calls never run inside a
  DatabaseWriter transaction.
  """

  alias Consigliere.Actor
  alias Consigliere.Adapters
  alias Consigliere.Git
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo

  def prepare(mission_id, spec) do
    sha = Map.fetch!(spec, :sha)
    github = Map.fetch!(spec, :github)
    adapter = Map.get(spec, :adapter, Adapters.github())

    with {:ok, ^sha} <-
           Git.push_sha(spec.mirror, spec.remote_url, sha, spec.ref),
         :success <- adapter.ci_status(github, sha),
         {:ok, pr} <- adapter.upsert_pr(github, spec.ref, sha),
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
    adapter = Map.get(spec, :adapter, Adapters.github())
    pr = Map.fetch!(spec, :pr)
    mission = Repo.get!(Mission, mission_id)

    with {:ok, auth} <- integration_auth(mission),
         :ok <- match_target(auth, mission, pr),
         :success <- adapter.ci_status(github, auth.target_sha),
         {:ok, merged_sha} <- adapter.merge(github, pr, auth.target_sha) do
      Missions.complete_integration(mission_id, Actor.system(), %{
        merged_sha: merged_sha,
        authorization_id: auth.id
      })
    else
      {:error, {:head_moved, _}} ->
        Missions.detect_integration_race(mission_id, Actor.system(), "head moved")

      :unknown ->
        {:error, {:ci_not_success, :unknown}}

      :pending ->
        {:error, {:ci_not_success, :pending}}

      :failure ->
        {:error, {:ci_not_success, :failure}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp integration_auth(%Mission{authorization_id: id, phase: "integrating"})
       when is_binary(id) do
    case Repo.get(Consigliere.Authorizations.Authorization, id) do
      %Consigliere.Authorizations.Authorization{scope: "integration"} = auth ->
        cond do
          not is_nil(auth.revoked_at) -> {:error, :authorization_revoked}
          not is_nil(auth.consumed_at) -> {:error, :authorization_consumed}
          expired?(auth) -> {:error, :authorization_expired}
          true -> {:ok, auth}
        end

      _ ->
        {:error, :authorization_invalid}
    end
  end

  defp integration_auth(_), do: {:error, :authorization_invalid}

  defp match_target(auth, mission, pr) do
    cond do
      to_string(auth.target_pull_request) != to_string(pr) ->
        {:error, :authorization_pr_mismatch}

      auth.target_sha != mission.current_delivery_sha ->
        {:error, :authorization_sha_mismatch}

      true ->
        :ok
    end
  end

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end
end
