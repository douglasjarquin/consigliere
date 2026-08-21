defmodule Consigliere.DeliveryTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Delivery
  alias Consigliere.Fixtures
  alias Consigliere.Git
  alias Consigliere.GitHub.Fake
  alias Consigliere.Missions
  alias Consigliere.Missions.Mission
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    root = Path.join(System.tmp_dir!(), "cs-deliv-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    mirror = Path.join(root, "trusted.git")
    dest = Path.join(root, "dest.git")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "ok.txt"), "ok\n")
    sha = Git.commit_all(workspace, "ok")
    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)
    Git.init_mirror(dest)
    {_, 0} = System.cmd("git", ["config", "receive.denyCurrentBranch", "ignore"], cd: dest)

    {:ok, github} = Fake.start_link()
    Fake.set_ci(github, sha, :success)

    mission = ready_mission!(sha)

    %{
      sha: sha,
      mirror: mirror,
      dest: dest,
      github: github,
      mission: mission,
      workspace: workspace
    }
  end

  defp ready_mission!(sha) do
    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Fixtures.grant_work_quietly(mission.id, Actor.boss())

    {:ok, %{mission: mission}} =
      Missions.start(mission.id, Actor.system(), %{
        workspace_path: "/tmp/cs-#{System.unique_integer([:positive])}"
      })

    {:ok, _} =
      Repo.update(
        Mission.changeset(Repo.get!(Mission, mission.id), %{
          phase: "ready_for_review",
          current_checkpoint_sha: sha
        })
      )

    Repo.get!(Mission, mission.id)
  end

  defp spec(ctx, overrides) do
    Map.merge(
      %{
        mirror: ctx.mirror,
        remote_url: ctx.dest,
        sha: ctx.sha,
        ref: "refs/heads/delivery",
        github: ctx.github
      },
      overrides
    )
  end

  test "prepare pushes from the mirror, reconciles a PR, and waits on integration auth", ctx do
    sentinel = Path.join(Path.dirname(ctx.dest), "origin-used")

    {_, 0} =
      System.cmd("git", ["remote", "add", "origin", "file://#{sentinel}"], cd: ctx.workspace)

    assert {:ok, %{mission: mission, pr: pr}} = Delivery.prepare(ctx.mission.id, spec(ctx, %{}))
    assert mission.phase == "awaiting_integration_authorization"
    assert mission.current_delivery_sha == ctx.sha
    assert pr.head_sha == ctx.sha
    refute File.exists?(sentinel)
    assert Git.mirror_has_commit?(ctx.dest, ctx.sha)
  end

  test "prepare refuses CI that belongs to a different SHA", ctx do
    Fake.set_ci(ctx.github, ctx.sha, :unknown)
    Fake.set_ci(ctx.github, "sha-other", :success)

    assert {:error, {:ci_not_success, :unknown}} =
             Delivery.prepare(ctx.mission.id, spec(ctx, %{}))

    assert Repo.get!(Mission, ctx.mission.id).phase == "ready_for_review"
  end

  test "merge at the expected head SHA completes the Mission", ctx do
    {:ok, %{mission: mission, pr: pr}} = Delivery.prepare(ctx.mission.id, spec(ctx, %{}))

    {:ok, mission} =
      Missions.grant_integration_authorization(mission.id, Actor.boss(), %{
        target_sha: ctx.sha,
        target_pull_request: to_string(pr.number)
      })

    assert mission.phase == "integrating"

    assert {:ok, mission} =
             Delivery.merge(mission.id, %{github: ctx.github, pr: pr.number})

    assert mission.phase == "completed"
    assert mission.current_delivery_sha == ctx.sha
  end

  test "merge detects a head-moved race and revokes integration authorization", ctx do
    {:ok, %{mission: mission, pr: pr}} = Delivery.prepare(ctx.mission.id, spec(ctx, %{}))

    {:ok, mission} =
      Missions.grant_integration_authorization(mission.id, Actor.boss(), %{
        target_sha: ctx.sha,
        target_pull_request: to_string(pr.number)
      })

    Fake.set_head(ctx.github, pr.number, "sha-moved")

    assert {:ok, mission} =
             Delivery.merge(mission.id, %{github: ctx.github, pr: pr.number})

    assert mission.phase == "awaiting_integration_authorization"
    assert "mission.integration_race_detected" in Fixtures.event_types(mission.id)
  end

  test "merge refuses an authorization granted for a different PR", ctx do
    {:ok, %{mission: mission, pr: pr}} = Delivery.prepare(ctx.mission.id, spec(ctx, %{}))

    {:ok, mission} =
      Missions.grant_integration_authorization(mission.id, Actor.boss(), %{
        target_sha: ctx.sha,
        target_pull_request: to_string(pr.number)
      })

    assert {:error, :authorization_pr_mismatch} =
             Delivery.merge(mission.id, %{github: ctx.github, pr: pr.number + 1})
  end
end
