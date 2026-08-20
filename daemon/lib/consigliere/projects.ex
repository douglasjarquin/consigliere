defmodule Consigliere.Projects do
  @moduledoc """
  Daemon-owned Project identity. Privileged remotes and mirrors never
  come from Agent-controlled Git config. Git work stays outside any
  SQLite transaction.
  """

  alias Consigliere.Actor
  alias Consigliere.DatabaseWriter
  alias Consigliere.Git
  alias Consigliere.Home
  alias Consigliere.Projects.Project
  alias Consigliere.Txn

  def register(attrs, %Actor{} = actor) do
    if actor.principal in ["boss", "daemon"] do
      do_register(attrs)
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  defp do_register(attrs) do
    source = Path.expand(Map.fetch!(attrs, :repository_path))
    url = Map.get(attrs, :repository_url) || "file://#{source}"
    branch = Map.get(attrs, :default_branch, "main")
    id = Ecto.UUID.generate()
    Home.ensure_dir!()
    mirror = Path.join(Home.trusted_projects_dir(), "#{id}.git")

    Git.init_mirror(mirror)
    sha = current_sha(source)

    case Git.import_sha(source, mirror, sha) do
      {:ok, _} ->
        DatabaseWriter.transaction(fn ->
          Txn.insert!(
            Project.changeset(%Project{id: id}, %{
              name: Map.fetch!(attrs, :name),
              repository_path: source,
              repository_url: url,
              default_branch: branch,
              trusted_mirror_path: mirror,
              dispatch_policy: Map.get(attrs, :dispatch_policy, %{}),
              validation_policy: Map.get(attrs, :validation_policy, %{}),
              integration_policy: Map.get(attrs, :integration_policy, %{})
            })
          )
        end)

      {:error, reason} ->
        File.rm_rf(mirror)
        {:error, reason}
    end
  end

  def provision_workspace(%Project{} = project, mission_id, sha) do
    dest = Path.join(Home.workspaces_dir(), mission_id)
    Git.materialize(project.trusted_mirror_path, dest, sha)
    dest
  end

  def head_sha(%Project{} = project) do
    {out, 0} =
      System.cmd(
        "git",
        ["--git-dir", project.trusted_mirror_path, "rev-list", "-n", "1", "--all"],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp current_sha(source) do
    {out, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source)
    String.trim(out)
  end
end
