defmodule Consigliere.Git do
  @moduledoc """
  Privileged Git operations. Never run from an Agent-controlled config:
  hooks, fsmonitor, credential helper, remotes, and aliases in the
  workspace are neutralized (docs/architecture/workspaces-and-git.md,
  ADR-006). These functions must not be called inside a DatabaseWriter
  transaction.
  """

  import Bitwise

  def empty_hooks_dir do
    dir = Path.join(System.tmp_dir!(), "cs-empty-git-hooks")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  def canonical_repository_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    case System.cmd("realpath", [expanded], stderr_to_stdout: true) do
      {output, 0} ->
        canonical = String.trim(output)

        if File.dir?(canonical) and File.exists?(Path.join(canonical, ".git")) do
          {:ok, canonical}
        else
          {:error, :not_a_repository}
        end

      {output, status} ->
        {:error, {:invalid_repository, status, String.trim(output)}}
    end
  rescue
    _ -> {:error, :invalid_repository}
  end

  def canonical_repository_path(_), do: {:error, :invalid_repository}

  def init_workspace(path) do
    File.mkdir_p!(path)
    git!(["init", "-b", "main"], cd: path)
    git!(["config", "user.email", "consigliere@local"], cd: path)
    git!(["config", "user.name", "consigliere"], cd: path)
    :ok
  end

  def init_mirror(path) do
    File.mkdir_p!(Path.dirname(path))
    privileged(["init", "--bare", "-b", "main", path])
    tighten_permissions!(path)
    :ok
  end

  def commit_all(workspace, message) do
    git!(["add", "-A"], cd: workspace)
    git!(["commit", "--allow-empty", "-m", message], cd: workspace)
    String.trim(git!(["rev-parse", "HEAD"], cd: workspace))
  end

  def verify_commit(workspace, sha) do
    case privileged(["cat-file", "-t", sha], cd: workspace) do
      {:ok, "commit\n"} -> :ok
      {:ok, other} -> {:error, {:not_a_commit, String.trim(other)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_ancestry(workspace, sha, nil), do: verify_commit(workspace, sha)

  def verify_ancestry(workspace, sha, base_sha) do
    with :ok <- verify_commit(workspace, sha),
         :ok <- verify_commit(workspace, base_sha) do
      case privileged(["merge-base", "--is-ancestor", base_sha, sha], cd: workspace) do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :not_ancestor}
      end
    end
  end

  def import_sha(workspace, mirror, sha, base_sha \\ nil) do
    with :ok <- verify_ancestry(workspace, sha, base_sha),
         :ok <- ensure_mirror(mirror),
         {:ok, _} <-
           privileged(
             [
               "fetch",
               Path.join(workspace, ".git"),
               "#{sha}:refs/consigliere/checkpoints/#{sha}"
             ],
             git_dir: mirror
           ) do
      {:ok, sha}
    end
  end

  def mirror_has_commit?(mirror, sha) do
    case privileged(["cat-file", "-t", sha], git_dir: mirror) do
      {:ok, "commit\n"} -> true
      _ -> false
    end
  end

  def materialize(mirror, dest, sha) do
    File.mkdir_p!(Path.dirname(dest))
    if path_exists?(dest), do: raise("workspace already exists: #{dest}")

    # file:// disables Git's local hardlink/alternate optimizations. Fetch
    # the exact SHA rather than cloning HEAD, because the trusted mirror
    # stores checkpoints on refs/consigliere/* rather than a branch.
    privileged(["init", "-b", "main", dest])

    privileged(
      [
        "fetch",
        "--",
        "file://#{Path.expand(mirror)}",
        "+refs/consigliere/*:refs/cs/*"
      ],
      cd: dest
    )

    privileged(["checkout", "--detach", sha], cd: dest)
    _ = privileged(["remote", "remove", "origin"], cd: dest)
    _ = privileged(["config", "--local", "--unset-regexp", "^remote\\..*"], cd: dest)
    _ = privileged(["config", "--local", "--unset-all", "credential.helper"], cd: dest)
    privileged(["config", "--local", "core.hooksPath", empty_hooks_dir()], cd: dest)
    tighten_permissions!(dest)

    case verify_workspace(dest, sha, mirror) do
      :ok -> :ok
      {:error, reason} -> raise "workspace isolation failed: #{inspect(reason)}"
    end
  end

  def branch_tip(source, branch) do
    ref = "refs/heads/#{branch}"

    case privileged(["rev-parse", "--verify", ref], cd: source) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _} -> {:error, {:missing_branch, branch}}
    end
  end

  def update_ref(mirror, ref, sha) do
    case privileged(["update-ref", ref, sha], git_dir: mirror) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def read_ref(mirror, ref) do
    case privileged(["rev-parse", "--verify", ref], git_dir: mirror) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, reason} -> {:error, reason}
    end
  end

  def project_base_ref(project_id), do: "refs/consigliere/projects/#{project_id}/base"

  def verify_workspace(workspace, sha, mirror \\ nil) do
    with {:ok, head} <- privileged(["rev-parse", "HEAD"], cd: workspace),
         true <- String.trim(head) == sha,
         :ok <- reject_alternates(workspace),
         :ok <- reject_privileged_remotes(workspace),
         :ok <- reject_credential_helpers(workspace),
         :ok <- verify_hooks_path(workspace),
         :ok <- verify_git_permissions(workspace),
         :ok <- reject_shared_objects(mirror, workspace) do
      :ok
    else
      false -> {:error, :head_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_shared_objects(nil, _), do: :ok

  defp reject_shared_objects(mirror, workspace) do
    if shares_object_inodes?(mirror, workspace) do
      {:error, :shared_objects}
    else
      :ok
    end
  end

  def shares_object_inodes?(mirror, workspace) do
    mirror_objects = object_inodes(mirror)
    workspace_objects = object_inodes(Path.join(workspace, ".git"))

    mirror_objects != MapSet.new() and
      not MapSet.disjoint?(mirror_objects, workspace_objects)
  end

  defp object_inodes(git_dir) do
    Path.join(git_dir, "objects")
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(MapSet.new(), fn path, acc ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, inode: inode}} -> MapSet.put(acc, inode)
        _ -> acc
      end
    end)
  end

  defp reject_alternates(workspace) do
    path = Path.join(workspace, ".git/objects/info/alternates")

    if File.exists?(path) do
      {:error, :alternates_present}
    else
      :ok
    end
  end

  defp reject_privileged_remotes(workspace) do
    case privileged(["remote"], cd: workspace) do
      {:ok, out} ->
        if String.trim(out) == "" do
          :ok
        else
          {:error, {:remotes_present, String.trim(out)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_credential_helpers(workspace) do
    case privileged(["config", "--local", "--get-all", "credential.helper"], cd: workspace) do
      {:ok, output} when output == "" -> :ok
      {:ok, _output} -> {:error, :credential_helper_present}
      {:error, _} -> :ok
    end
  end

  defp verify_hooks_path(workspace) do
    case privileged(["config", "--local", "--get", "core.hooksPath"], cd: workspace) do
      {:ok, output} ->
        if Path.expand(String.trim(output)) == Path.expand(empty_hooks_dir()) do
          :ok
        else
          {:error, :hooks_path_present}
        end

      {:error, _} ->
        {:error, :hooks_path_missing}
    end
  end

  defp verify_git_permissions(workspace) do
    paths = [Path.join(workspace, ".git") | Path.wildcard(Path.join(workspace, ".git/**/*"))]

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, :git_symlink}}

        {:ok, %File.Stat{mode: mode}} when band(mode, 0o077) != 0 ->
          {:halt, {:error, :unsafe_permissions}}

        {:ok, _} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:git_stat_failed, reason}}}
      end
    end)
  end

  defp tighten_permissions!(root) do
    paths =
      [root, Path.join(root, ".git")] ++
        Path.wildcard(Path.join(root, "**/*")) ++
        Path.wildcard(Path.join(root, ".git/**/*"))

    Enum.each(paths, fn path ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> File.chmod!(path, 0o700)
        {:ok, %File.Stat{type: :regular, mode: mode}} -> File.chmod!(path, band(mode, 0o700))
        {:ok, %File.Stat{type: :symlink}} -> :ok
        _ -> :ok
      end
    end)
  end

  defp path_exists?(path) do
    case File.lstat(path) do
      {:ok, _} -> true
      {:error, :enoent} -> false
      {:error, _} -> true
    end
  end

  def push_sha(mirror, remote_url, sha, ref) do
    with true <- mirror_has_commit?(mirror, sha),
         {:ok, _} <- privileged(["push", remote_url, "#{sha}:#{ref}"], git_dir: mirror) do
      {:ok, sha}
    else
      false -> {:error, :missing_from_mirror}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_mirror(path) do
    if File.dir?(path), do: :ok, else: init_mirror(path)
  end

  defp git!(args, opts) do
    case git_cmd(args, opts) do
      {:ok, out} -> out
      {:error, reason} -> raise "git #{inspect(args)} failed: #{inspect(reason)}"
    end
  end

  defp privileged([cmd | rest], opts \\ []) do
    flags = neutralizing_flags(cmd)
    git_dir_args = git_dir_args(opts)
    git_cmd(git_dir_args ++ flags ++ [cmd | rest], Keyword.put(opts, :env, privileged_env()))
  end

  defp git_dir_args(opts) do
    case Keyword.get(opts, :git_dir) do
      nil -> []
      path -> ["--git-dir", path]
    end
  end

  defp git_cmd(args, opts) do
    env = Keyword.get(opts, :env, System.get_env())
    cmd_opts = [stderr_to_stdout: true, env: env]

    cmd_opts =
      case Keyword.get(opts, :cd) do
        nil -> cmd_opts
        path -> Keyword.put(cmd_opts, :cd, path)
      end

    git = System.find_executable("git") || "git"

    case System.cmd(git, args, cmd_opts) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, {status, out}}
    end
  end

  defp neutralizing_flags(cmd) do
    [
      "-c",
      "core.hooksPath=#{empty_hooks_dir()}",
      "-c",
      "core.fsmonitor=",
      "-c",
      "core.useBuiltinFSMonitor=false",
      "-c",
      "credential.helper=",
      "-c",
      "alias.#{cmd}=#{cmd}"
    ]
  end

  defp privileged_env do
    %{
      "PATH" => "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_OPTIONAL_LOCKS" => "1",
      "GIT_ASKPASS" => "",
      "GIT_SSH_COMMAND" => "",
      "GIT_TRACE" => "0",
      "LANG" => "C",
      "LC_ALL" => "C"
    }
  end
end
