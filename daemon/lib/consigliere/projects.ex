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
    base_ref = Git.project_base_ref(id)

    with {:ok, sha} <- Git.branch_tip(source, branch),
         {:ok, _} <- Git.import_sha(source, mirror, sha),
         :ok <- Git.update_ref(mirror, base_ref, sha) do
      DatabaseWriter.transaction(fn ->
        Txn.insert!(
          Project.changeset(%Project{id: id}, %{
            name: Map.fetch!(attrs, :name),
            repository_path: source,
            repository_url: url,
            default_branch: branch,
            trusted_mirror_path: mirror,
            base_sha: sha,
            base_ref: base_ref,
            dispatch_policy: Map.get(attrs, :dispatch_policy, %{}),
            validation_policy: Map.get(attrs, :validation_policy, %{}),
            integration_policy: Map.get(attrs, :integration_policy, %{})
          })
        )
      end)
    else
      {:error, reason} ->
        File.rm_rf(mirror)
        {:error, reason}
    end
  end

  def provision_workspace(%Project{} = project, mission_id, sha) do
    unless valid_mission_id?(mission_id) do
      raise "unsafe mission workspace id"
    end

    dest = Path.join(Home.workspaces_dir(), mission_id)
    expected = Path.expand(dest)
    root = Path.expand(Home.workspaces_dir())

    unless expected == Path.join(root, mission_id) do
      raise "workspace path escaped CS_HOME"
    end

    Git.materialize(project.trusted_mirror_path, dest, sha)
    dest
  end

  def head_sha(%Project{base_sha: sha}) when is_binary(sha) and sha != "", do: sha

  def head_sha(%Project{} = project) do
    ref = project.base_ref || Git.project_base_ref(project.id)

    case Git.read_ref(project.trusted_mirror_path, ref) do
      {:ok, sha} -> sha
      {:error, reason} -> raise "project base ref missing: #{inspect(reason)}"
    end
  end

  defp valid_mission_id?(id) when is_binary(id) do
    id != "" and not String.contains?(id, ["/", "\\", ".."])
  end

  defp valid_mission_id?(_), do: false
end
