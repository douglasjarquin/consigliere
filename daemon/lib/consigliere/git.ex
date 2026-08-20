defmodule Consigliere.Git do
  @moduledoc """
  Privileged Git operations. Never run from an Agent-controlled config:
  hooks, fsmonitor, credential helper, remotes, and aliases in the
  workspace are neutralized (docs/architecture/workspaces-and-git.md,
  ADR-006). These functions must not be called inside a DatabaseWriter
  transaction.
  """

  def empty_hooks_dir do
    dir = Path.join(System.tmp_dir!(), "cs-empty-git-hooks")
    File.mkdir_p!(dir)
    dir
  end

  def init_workspace(path) do
    File.mkdir_p!(path)
    git!(["init", "-b", "main"], cd: path)
    git!(["config", "user.email", "consigliere@local"], cd: path)
    git!(["config", "user.name", "consigliere"], cd: path)
    :ok
  end

  def init_mirror(path) do
    File.mkdir_p!(Path.dirname(path))
    git!(["init", "--bare", "-b", "main", path])
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
    if File.dir?(dest), do: raise("workspace already exists: #{dest}")

    git!(["clone", "--", mirror, dest])
    git!(["checkout", "--detach", sha], cd: dest)
    _ = git_cmd(["remote", "remove", "origin"], cd: dest)
    :ok
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

  defp git!(args, opts \\ []) do
    case git_cmd(args, opts) do
      {:ok, out} -> out
      {:error, reason} -> raise "git #{inspect(args)} failed: #{inspect(reason)}"
    end
  end

  defp privileged([cmd | rest], opts) do
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
