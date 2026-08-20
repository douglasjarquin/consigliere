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
    assert {:ok, project} =
             Projects.register(
               %{name: "demo", repository_path: source, repository_url: "file://#{source}"},
               Actor.boss()
             )

    assert project.default_branch == "main"
    assert String.starts_with?(project.trusted_mirror_path, Home.trusted_projects_dir())
    assert File.dir?(project.trusted_mirror_path)
    assert Git.mirror_has_commit?(project.trusted_mirror_path, sha)
    assert Repo.get!(Project, project.id).repository_url == "file://#{source}"
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

  test "an Attempt principal cannot register a Project", %{source: source} do
    assert {:error, {:unauthorized, :principal}} =
             Projects.register(
               %{name: "x", repository_path: source, repository_url: "file://#{source}"},
               Actor.attempt("a", "f")
             )
  end
end
