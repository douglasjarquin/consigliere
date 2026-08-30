defmodule Consigliere.Projects do
  @moduledoc """
  Daemon-owned Project identity. Privileged remotes and mirrors never
  come from Agent-controlled Git config. Git work stays outside any
  SQLite transaction.
  """

  import Bitwise

  alias Consigliere.Actor
  alias Consigliere.DatabaseWriter
  alias Consigliere.Git
  alias Consigliere.Home
  alias Consigliere.Missions.Mission
  alias Consigliere.Projects.Project
  alias Consigliere.Repo
  alias Consigliere.Txn
  alias Consigliere.Workspaces.Workspace

  @authorized_principals ["boss", "daemon"]
  @max_branch_bytes 256
  @max_url_bytes 4096

  def register(attrs, %Actor{} = actor) do
    if actor.principal in @authorized_principals,
      do: do_register(attrs),
      else: {:error, {:unauthorized, :principal}}
  end

  defp do_register(attrs) do
    with {:ok, name} <- required_string(attrs, :name),
         {:ok, source} <- canonical_source(attrs),
         {:ok, branch} <- valid_branch(attr(attrs, :default_branch, "main")),
         {:ok, url} <- canonical_url(attr(attrs, :repository_url), source) do
      case Repo.get_by(Project, repository_path: source) do
        %Project{} ->
          {:error, {:conflict, :project_exists}}

        nil ->
          id = Ecto.UUID.generate()
          Home.ensure_dir!()
          mirror = Path.join(Home.trusted_projects_dir(), "#{id}.git")
          base_ref = Git.project_base_ref(id)

          Git.init_mirror(mirror)

          with {:ok, sha} <- Git.branch_tip(source, branch),
               {:ok, _} <- Git.import_sha(source, mirror, sha),
               :ok <- Git.update_ref(mirror, base_ref, sha) do
            result =
              DatabaseWriter.transaction(fn ->
                project =
                  Txn.insert!(
                    Project.changeset(%Project{id: id}, %{
                      name: name,
                      repository_path: source,
                      repository_url: url,
                      default_branch: branch,
                      trusted_mirror_path: mirror,
                      base_sha: sha,
                      base_ref: base_ref,
                      dispatch_policy: attr(attrs, :dispatch_policy, %{}),
                      validation_policy: attr(attrs, :validation_policy, %{}),
                      integration_policy: attr(attrs, :integration_policy, %{})
                    })
                  )

                Txn.append_event!("project.registered", "project", project.id, %{
                  default_branch: project.default_branch,
                  base_ref: project.base_ref,
                  base_sha: project.base_sha
                })

                project
              end)

            case result do
              {:ok, _project} ->
                result

              other ->
                _ = quarantine_mirror(mirror, id)
                other
            end
          else
            {:error, reason} ->
              quarantine_mirror(mirror, id)
              {:error, reason}
          end
      end
    end
  end

  def refresh_base(project_id, %Actor{} = actor) do
    if actor.principal in @authorized_principals do
      case Repo.get(Project, project_id) do
        %Project{} = project -> refresh_project_base(project)
        nil -> {:error, :not_found}
      end
    else
      {:error, {:unauthorized, :principal}}
    end
  end

  def verify_workspace_identity(
        %Project{} = project,
        %Mission{} = mission,
        %Workspace{} = workspace,
        expected_sha \\ nil
      ) do
    expected_sha = expected_sha || mission.current_checkpoint_sha || mission.base_sha

    cond do
      mission.project_id != project.id ->
        {:error, :mission_project_mismatch}

      workspace.project_id != project.id ->
        {:error, :workspace_project_mismatch}

      is_nil(mission.base_sha) or mission.base_sha == "" ->
        {:error, :mission_base_missing}

      workspace.base_sha != mission.base_sha ->
        {:error, :workspace_base_mismatch}

      workspace.parent_checkpoint_sha != mission.current_checkpoint_sha ->
        {:error, :workspace_checkpoint_mismatch}

      blank?(workspace.lease_id) ->
        {:error, :workspace_lease_missing}

      blank?(workspace.fencing_token) ->
        {:error, :workspace_generation_missing}

      not safe_workspace_path?(workspace.path, mission.id) ->
        {:error, :workspace_path_invalid}

      project.base_ref != Git.project_base_ref(project.id) ->
        {:error, :project_base_ref_mismatch}

      not is_binary(project.base_sha) or project.base_sha == "" ->
        {:error, :project_base_missing}

      not Git.mirror_has_commit?(project.trusted_mirror_path, project.base_sha) ->
        {:error, :project_base_missing}

      not base_ref_matches?(project) ->
        {:error, :project_base_ref_stale}

      not is_binary(expected_sha) or expected_sha == "" ->
        {:error, :checkpoint_missing}

      not trusted_expected_sha?(project, mission, expected_sha) ->
        {:error, :checkpoint_not_trusted}

      true ->
        Git.verify_workspace(workspace.path, expected_sha, project.trusted_mirror_path)
    end
  end

  defp trusted_expected_sha?(project, mission, sha) do
    if sha == mission.base_sha or sha == mission.current_checkpoint_sha do
      Git.mirror_has_commit?(project.trusted_mirror_path, sha)
    else
      Git.valid_full_sha?(sha)
    end
  end

  def trusted_identity?(%Project{} = project) do
    is_binary(project.base_sha) and project.base_sha != "" and
      is_binary(project.base_ref) and project.base_ref != "" and
      is_binary(project.trusted_mirror_path) and project.trusted_mirror_path != ""
  end

  def trusted_identity?(_), do: false

  def workspace_path_shape?(path, mission_id)
      when is_binary(path) and is_binary(mission_id) do
    root = Path.expand(Home.workspaces_dir())
    expanded = Path.expand(path)
    name = Path.basename(expanded)

    Path.dirname(expanded) == root and
      (name == mission_id or String.starts_with?(name, mission_id <> "-"))
  end

  def workspace_path_shape?(_, _), do: false

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

    unless safe_workspace_path?(dest, mission_id, false) do
      raise "unsafe workspace path"
    end

    unless Git.mirror_has_commit?(project.trusted_mirror_path, sha) do
      raise "workspace SHA is not trusted"
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

  defp refresh_project_base(project) do
    base_ref = project.base_ref || Git.project_base_ref(project.id)

    with {:ok, source} <- Git.canonical_repository_path(project.repository_path),
         {:ok, branch} <- valid_branch(project.default_branch),
         {:ok, sha} <- Git.branch_tip(source, branch),
         {:ok, _} <- Git.import_sha(source, project.trusted_mirror_path, sha),
         :ok <- Git.update_ref(project.trusted_mirror_path, base_ref, sha) do
      DatabaseWriter.transaction(fn ->
        latest = Repo.get!(Project, project.id)

        if latest.repository_path != source or latest.default_branch != branch do
          Txn.illegal(latest.default_branch, branch, :project_identity_changed)
        end

        refreshed = Txn.update!(Project.changeset(latest, %{base_sha: sha, base_ref: base_ref}))

        Txn.append_event!("project.base_refreshed", "project", refreshed.id, %{
          default_branch: refreshed.default_branch,
          base_ref: refreshed.base_ref,
          base_sha: refreshed.base_sha
        })

        refreshed
      end)
    end
  end

  defp canonical_source(attrs) do
    attrs
    |> attr(:repository_path)
    |> Git.canonical_repository_path()
  end

  defp canonical_url(nil, source), do: {:ok, "file://#{source}"}

  defp canonical_url(url, source) when is_binary(url) do
    cond do
      byte_size(url) == 0 or byte_size(url) > @max_url_bytes ->
        {:error, :invalid_repository_url}

      String.starts_with?(url, "file://") ->
        case Git.canonical_repository_path(String.replace_prefix(url, "file://", "")) do
          {:ok, ^source} -> {:ok, "file://#{source}"}
          {:ok, _other} -> {:ok, url}
          {:error, :not_a_repository} -> {:ok, url}
          {:error, _reason} -> {:ok, url}
        end

      true ->
        {:ok, url}
    end
  end

  defp canonical_url(_url, _source), do: {:error, :invalid_repository_url}

  defp valid_branch(branch)
       when is_binary(branch) and byte_size(branch) in 1..@max_branch_bytes do
    invalid? =
      branch != String.trim(branch) or
        String.starts_with?(branch, "-") or
        String.ends_with?(branch, ".") or
        String.contains?(branch, ["..", "//", "\\", "@{", "\u0000", "\n", "\r", "\t"])

    if invalid?, do: {:error, :invalid_branch}, else: {:ok, branch}
  end

  defp valid_branch(_), do: {:error, :invalid_branch}

  defp required_string(attrs, key) do
    case attr(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp base_ref_matches?(%Project{} = project) do
    case Git.read_ref(project.trusted_mirror_path, project.base_ref) do
      {:ok, sha} -> sha == project.base_sha
      _ -> false
    end
  end

  defp safe_workspace_path?(path, mission_id, require_existing \\ true)

  defp safe_workspace_path?(path, mission_id, require_existing)
       when is_binary(path) and is_binary(mission_id) do
    root = Path.expand(Home.workspaces_dir())
    expanded = Path.expand(path)
    name = Path.basename(expanded)
    valid_name = name == mission_id or String.starts_with?(name, mission_id <> "-")

    valid_root? = workspace_path_shape?(expanded, mission_id) and valid_name

    if valid_root? do
      components = [root, expanded]

      Enum.all?(components, fn component ->
        case File.lstat(component) do
          {:ok, %File.Stat{type: :symlink}} -> false
          {:ok, %File.Stat{mode: mode}} -> band(mode, 0o077) == 0
          {:error, :enoent} -> not require_existing and component == expanded
          _ -> false
        end
      end)
    else
      false
    end
  end

  defp safe_workspace_path?(_, _, _), do: false

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp quarantine_mirror(mirror, project_id) do
    destination = Path.join(Home.evidence_dir(), "unclaimed-projects/#{project_id}.git")
    File.mkdir_p!(Path.dirname(destination))
    File.chmod!(Path.dirname(destination), 0o700)

    case File.rename(mirror, destination) do
      :ok -> true
      {:error, :enoent} -> true
      {:error, _reason} -> false
    end
  end

  defp valid_mission_id?(id) when is_binary(id) do
    id != "" and not String.contains?(id, ["/", "\\", ".."])
  end

  defp valid_mission_id?(_), do: false
end
