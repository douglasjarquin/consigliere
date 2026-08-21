defmodule Consigliere.GitTest do
  use ExUnit.Case, async: false

  alias Consigliere.Git

  setup do
    root = Path.join(System.tmp_dir!(), "cs-git-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    mirror = Path.join(root, "trusted.git")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, mirror: mirror}
  end

  test "materialize copies objects instead of hardlinking the mirror", %{
    workspace: workspace,
    mirror: mirror,
    root: root
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "hello.txt"), "hi\n")
    sha = Git.commit_all(workspace, "hello")
    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)

    dest = Path.join(root, "clone")
    Git.materialize(mirror, dest, sha)
    refute Git.shares_object_inodes?(mirror, dest)
    refute File.exists?(Path.join(dest, ".git/objects/info/alternates"))
    assert Git.verify_workspace(dest, sha, mirror) == :ok
  end

  test "imports a committed SHA into the trusted mirror", %{workspace: workspace, mirror: mirror} do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "hello.txt"), "hi\n")
    sha = Git.commit_all(workspace, "hello")

    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)
    assert Git.mirror_has_commit?(mirror, sha)

    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)
  end

  test "refuses a SHA that is not a commit in the workspace", %{
    workspace: workspace,
    mirror: mirror
  } do
    Git.init_workspace(workspace)
    Git.commit_all(workspace, "empty")
    assert {:error, _} = Git.import_sha(workspace, mirror, String.duplicate("a", 40))
    refute File.dir?(mirror) && Git.mirror_has_commit?(mirror, String.duplicate("a", 40))
  end

  test "refuses a SHA that is not a descendant of the base", %{
    workspace: workspace,
    mirror: mirror
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "a.txt"), "a\n")
    base = Git.commit_all(workspace, "a")

    other = Path.join(Path.dirname(workspace), "other")
    Git.init_workspace(other)
    File.write!(Path.join(other, "b.txt"), "b\n")
    unrelated = Git.commit_all(other, "b")
    {_, 0} = System.cmd("git", ["remote", "add", "other", other], cd: workspace)
    {_, 0} = System.cmd("git", ["fetch", "other"], cd: workspace)

    assert {:error, :not_ancestor} = Git.import_sha(workspace, mirror, unrelated, base)
  end

  test "a workspace pre-commit hook does not run during privileged import", %{
    workspace: workspace,
    mirror: mirror,
    root: root
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "ok.txt"), "ok\n")
    sha = Git.commit_all(workspace, "ok")

    sentinel = Path.join(root, "hook-fired")
    hooks = Path.join(workspace, ".git/hooks")
    File.mkdir_p!(hooks)
    hook = Path.join(hooks, "pre-commit")
    File.write!(hook, "#!/bin/sh\ntouch '#{sentinel}'\n")
    File.chmod!(hook, 0o755)

    update = Path.join(hooks, "update")
    File.write!(update, "#!/bin/sh\ntouch '#{sentinel}'\n")
    File.chmod!(update, 0o755)

    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)
    refute File.exists?(sentinel)
  end

  test "a malicious fsmonitor and credential.helper in the workspace are ignored", %{
    workspace: workspace,
    mirror: mirror,
    root: root
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "ok.txt"), "ok\n")
    sha = Git.commit_all(workspace, "ok")

    sentinel = Path.join(root, "helper-fired")
    helper = Path.join(root, "evil-helper")
    File.write!(helper, "#!/bin/sh\ntouch '#{sentinel}'\n")
    File.chmod!(helper, 0o755)

    {_, 0} = System.cmd("git", ["config", "core.fsmonitor", helper], cd: workspace)
    {_, 0} = System.cmd("git", ["config", "credential.helper", helper], cd: workspace)

    {_, 0} =
      System.cmd("git", ["remote", "add", "origin", "https://evil.example/repo.git"],
        cd: workspace
      )

    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)
    refute File.exists?(sentinel)
    assert Git.mirror_has_commit?(mirror, sha)
  end

  test "an aliased cat-file in the workspace config cannot hijack privileged git", %{
    workspace: workspace,
    mirror: mirror,
    root: root
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "ok.txt"), "ok\n")
    sha = Git.commit_all(workspace, "ok")

    sentinel = Path.join(root, "alias-fired")

    {_, 0} =
      System.cmd("git", ["config", "alias.cat-file", "!touch #{sentinel} && git cat-file"],
        cd: workspace
      )

    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)
    refute File.exists?(sentinel)
  end

  test "a marker file is not treated as a durable checkpoint", %{
    workspace: workspace,
    mirror: mirror
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "hello.txt"), "committed\n")
    sha = Git.commit_all(workspace, "committed")
    File.write!(Path.join(workspace, "CLEAN"), "I am a marker\n")
    File.write!(Path.join(workspace, "hello.txt"), "dirty uncommitted\n")

    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)

    {blob, 0} =
      System.cmd("git", ["--git-dir", mirror, "show", "#{sha}:hello.txt"], stderr_to_stdout: true)

    assert blob == "committed\n"
    refute blob =~ "dirty"
  end

  test "privileged push goes from the trusted mirror, not the workspace origin", %{
    workspace: workspace,
    mirror: mirror,
    root: root
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "ok.txt"), "ok\n")
    sha = Git.commit_all(workspace, "ok")
    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)

    dest = Path.join(root, "dest.git")
    Git.init_mirror(dest)
    {_, 0} = System.cmd("git", ["config", "receive.denyCurrentBranch", "ignore"], cd: dest)

    sentinel = Path.join(root, "origin-used")

    {_, 0} =
      System.cmd("git", ["remote", "add", "origin", "file://#{sentinel}"], cd: workspace)

    assert {:ok, ^sha} = Git.push_sha(mirror, dest, sha, "refs/heads/delivery")
    refute File.exists?(sentinel)
    assert Git.mirror_has_commit?(dest, sha)
  end

  test "privileged push refuses a SHA the trusted mirror does not have", %{
    workspace: workspace,
    mirror: mirror,
    root: root
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "ok.txt"), "ok\n")
    sha = Git.commit_all(workspace, "ok")
    Git.init_mirror(mirror)

    dest = Path.join(root, "dest.git")
    Git.init_mirror(dest)

    assert {:error, :missing_from_mirror} =
             Git.push_sha(mirror, dest, sha, "refs/heads/delivery")
  end

  test "a workspace update hook does not run during privileged push", %{
    workspace: workspace,
    mirror: mirror,
    root: root
  } do
    Git.init_workspace(workspace)
    File.write!(Path.join(workspace, "ok.txt"), "ok\n")
    sha = Git.commit_all(workspace, "ok")
    assert {:ok, ^sha} = Git.import_sha(workspace, mirror, sha)

    dest = Path.join(root, "dest.git")
    Git.init_mirror(dest)
    {_, 0} = System.cmd("git", ["config", "receive.denyCurrentBranch", "ignore"], cd: dest)

    sentinel = Path.join(root, "hook-fired")
    hooks = Path.join(workspace, ".git/hooks")
    File.mkdir_p!(hooks)

    for name <- ["pre-push", "pre-commit", "update"] do
      path = Path.join(hooks, name)
      File.write!(path, "#!/bin/sh\ntouch '#{sentinel}'\n")
      File.chmod!(path, 0o755)
    end

    assert {:ok, ^sha} = Git.push_sha(mirror, dest, sha, "refs/heads/delivery")
    refute File.exists?(sentinel)
    assert Git.mirror_has_commit?(dest, sha)
  end
end
