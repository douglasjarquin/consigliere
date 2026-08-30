defmodule Consigliere.ProjectsTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.Fixtures
  alias Consigliere.Git
  alias Consigliere.Home
  alias Consigliere.Projects
  alias Consigliere.Projects.Project
  alias Consigliere.Repo

  setup do
    Fixtures.reset_phase1_tables!()
    source = Path.join(System.tmp_dir!(), "cs-proj-src-#{System.unique_integer([:positive])}")
    Git.init_workspace(source)
    File.write!(Path.join(source, "README"), "hello\n")
    sha = Git.commit_all(source, "init")
    on_exit(fn -> File.rm_rf(source) end)
    %{source: source, sha: sha}
  end

  test "register creates a Project and a trusted mirror under CS_HOME", %{
    source: source,
    sha: sha
  } do
    {:ok, canonical_source} = Git.canonical_repository_path(source)

    assert {:ok, project} =
             Projects.register(
               %{name: "demo", repository_path: source, repository_url: "file://#{source}"},
               Actor.boss()
             )

    assert project.default_branch == "main"
    assert String.starts_with?(project.trusted_mirror_path, Home.trusted_projects_dir())
    assert File.dir?(project.trusted_mirror_path)
    assert Git.mirror_has_commit?(project.trusted_mirror_path, sha)
    assert Repo.get!(Project, project.id).repository_url == "file://#{canonical_source}"
    assert Fixtures.event_types(project.id) == ["project.registered"]
  end

  test "register stores the canonical source path when given a symlink", %{source: source} do
    link = Path.join(System.tmp_dir!(), "cs-proj-link-#{System.unique_integer([:positive])}")
    File.ln_s!(source, link)
    on_exit(fn -> File.rm(link) end)
    {:ok, canonical_source} = Git.canonical_repository_path(source)

    assert {:ok, project} =
             Projects.register(
               %{name: "demo", repository_path: link, repository_url: "file://#{link}"},
               Actor.boss()
             )

    assert project.repository_path == canonical_source
    assert project.repository_url == "file://#{canonical_source}"
  end

  test "register rejects a duplicate canonical source", %{source: source} do
    assert {:ok, _project} =
             Projects.register(
               %{name: "first", repository_path: source, repository_url: "file://first"},
               Actor.boss()
             )

    assert {:error, {:conflict, :project_exists}} =
             Projects.register(
               %{name: "second", repository_path: source, repository_url: "file://second"},
               Actor.boss()
             )
  end

  test "refresh_base advances only the Project base and records an audit event", %{
    source: source,
    sha: sha
  } do
    assert {:ok, project} =
             Projects.register(
               %{name: "demo", repository_path: source, repository_url: "file://#{source}"},
               Actor.boss()
             )

    {:ok, mission} =
      Consigliere.Missions.create(
        Fixtures.mission_attrs(%{project_id: project.id}),
        Actor.boss()
      )

    {:ok, mission} = Consigliere.Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Consigliere.Missions.grant_work_authorization(mission.id, Actor.boss())
    assert mission.base_sha == sha

    File.write!(Path.join(source, "later.txt"), "later\n")
    later = Git.commit_all(source, "later")

    assert {:ok, refreshed} = Projects.refresh_base(project.id, Actor.boss())
    assert refreshed.base_sha == later
    assert Repo.get!(Project, project.id).base_sha == later
    assert Repo.get!(Consigliere.Missions.Mission, mission.id).base_sha == sha
    assert "project.base_refreshed" in Fixtures.event_types(project.id)
  end

  test "workspace identity verification fails closed for changed durable identities", %{
    source: source
  } do
    assert {:ok, project} =
             Projects.register(
               %{name: "demo", repository_path: source, repository_url: "file://#{source}"},
               Actor.boss()
             )

    {:ok, mission} =
      Consigliere.Missions.create(
        Fixtures.mission_attrs(%{project_id: project.id}),
        Actor.boss()
      )

    {:ok, mission} = Consigliere.Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Consigliere.Missions.grant_work_authorization(mission.id, Actor.boss())
    dest = Path.join(Home.workspaces_dir(), mission.id)

    {:ok, %{workspace: workspace}} =
      Consigliere.Missions.start(mission.id, Actor.system(), %{workspace_path: dest})

    assert :ok = Projects.verify_workspace_identity(project, mission, workspace)

    changed = %{workspace | base_sha: "not-the-authorized-base"}

    assert {:error, :workspace_base_mismatch} =
             Projects.verify_workspace_identity(project, mission, changed)
  end

  test "provision_workspace clones source at the SHA with no origin remote", %{
    source: source,
    sha: sha
  } do
    {:ok, project} =
      Projects.register(
        %{name: "demo", repository_path: source, repository_url: "file://#{source}"},
        Actor.boss()
      )

    mission_id = Ecto.UUID.generate()
    dest = Projects.provision_workspace(project, mission_id, sha)
    assert File.exists?(Path.join(dest, "README"))
    {origin, status} = System.cmd("git", ["remote"], cd: dest)
    assert status == 0
    refute origin =~ "origin"
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dest)
    assert String.trim(head) == sha
  end

  test "register imports the configured default branch tip, not checkout HEAD", %{source: source} do
    {main, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source)
    main = String.trim(main)

    {_, 0} = System.cmd("git", ["checkout", "-b", "feature"], cd: source)
    File.write!(Path.join(source, "feature.txt"), "later\n")
    feature = Git.commit_all(source, "feature")
    refute feature == main

    assert {:ok, project} =
             Projects.register(
               %{
                 name: "demo",
                 repository_path: source,
                 repository_url: "file://#{source}-feature",
                 default_branch: "main"
               },
               Actor.boss()
             )

    assert project.base_sha == main
    assert project.base_ref == "refs/consigliere/projects/#{project.id}/base"
    assert Projects.head_sha(project) == main
    refute Projects.head_sha(project) == feature
  end

  test "importing a Mission checkpoint does not move another Mission's project base", %{
    source: source,
    sha: sha
  } do
    {:ok, project} =
      Projects.register(
        %{name: "demo", repository_path: source, repository_url: "file://#{source}-ckpt"},
        Actor.boss()
      )

    File.write!(Path.join(source, "later.txt"), "ckpt\n")
    later = Git.commit_all(source, "checkpoint")
    assert {:ok, ^later} = Git.import_sha(source, project.trusted_mirror_path, later, sha)

    assert Projects.head_sha(project) == sha
    refute Projects.head_sha(project) == later
  end

  test "provision_workspace does not hardlink trusted-mirror objects", %{
    source: source,
    sha: sha
  } do
    {:ok, project} =
      Projects.register(
        %{name: "demo", repository_path: source, repository_url: "file://#{source}-hl"},
        Actor.boss()
      )

    dest = Projects.provision_workspace(project, Ecto.UUID.generate(), sha)
    refute Git.shares_object_inodes?(project.trusted_mirror_path, dest)
    refute File.exists?(Path.join(dest, ".git/objects/info/alternates"))
  end

  test "an Attempt principal cannot register a Project", %{source: source} do
    assert {:error, {:unauthorized, :principal}} =
             Projects.register(
               %{name: "x", repository_path: source, repository_url: "file://#{source}"},
               Actor.attempt("a", "f")
             )
  end
end
