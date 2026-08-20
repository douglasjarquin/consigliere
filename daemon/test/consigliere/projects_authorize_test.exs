defmodule Consigliere.ProjectsAuthorizeTest do
  use ExUnit.Case, async: false

  alias Consigliere.Actor
  alias Consigliere.API.Protocol
  alias Consigliere.Fixtures
  alias Consigliere.Git
  alias Consigliere.Home
  alias Consigliere.Missions
  alias Consigliere.Projects

  setup do
    Fixtures.reset_phase1_tables!()
    source = Path.join(System.tmp_dir!(), "cs-auth-src-#{System.unique_integer([:positive])}")
    Git.init_workspace(source)
    File.write!(Path.join(source, "hello.txt"), "hi\n")
    sha = Git.commit_all(source, "init")
    on_exit(fn -> File.rm_rf(source) end)
    %{source: source, sha: sha}
  end

  test "mission.create without project_id is rejected" do
    {:ok, map} =
      JSON.decode(
        Protocol.handle(
          JSON.encode!(%{
            "v" => 1,
            "id" => "c",
            "op" => "mission.create",
            "actor" => %{"principal" => "boss"},
            "payload" => %{"objective" => "o", "scope" => "s", "acceptance_criteria" => "a"}
          })
        )
      )

    assert map["ok"] == false
    assert map["error"]["code"] == "invalid"
  end

  test "authorizing a Mission clones the Project at the trusted SHA", %{source: source, sha: sha} do
    {:ok, project} =
      Projects.register(
        %{name: "demo", repository_path: source, repository_url: "file://#{source}"},
        Actor.boss()
      )

    {:ok, mission} =
      Missions.create(Fixtures.mission_attrs(%{project_id: project.id}), Actor.boss())

    {:ok, mission} = Missions.submit_for_authorization(mission.id, Actor.boss())
    {:ok, mission} = Missions.grant_work_authorization(mission.id, Actor.boss())

    dest = Path.join(Home.workspaces_dir(), mission.id)
    assert File.exists?(Path.join(dest, "hello.txt"))
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dest)
    assert String.trim(head) == sha
    {remotes, 0} = System.cmd("git", ["remote"], cd: dest)
    refute remotes =~ "origin"
  end
end
