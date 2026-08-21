defmodule Consigliere.HomeTest do
  use ExUnit.Case, async: false

  alias Consigliere.Home

  test "dir/0 respects CS_HOME when set" do
    System.put_env("CS_HOME", "/tmp/some-cs-home")
    on_exit(fn -> System.delete_env("CS_HOME") end)

    assert Home.dir() == "/tmp/some-cs-home"
  end

  test "dir/0 falls back to ~/.consigliere when CS_HOME is unset" do
    System.delete_env("CS_HOME")

    assert Home.dir() == Path.expand("~/.consigliere")
  end

  test "ensure_dir!/1 creates the directory and returns it" do
    home = Path.join(System.tmp_dir!(), "cs-home-test-#{System.unique_integer([:positive])}")
    refute File.exists?(home)
    on_exit(fn -> File.rm_rf!(home) end)

    assert Home.ensure_dir!(home) == home
    assert File.dir?(home)
    assert Bitwise.band(File.stat!(home).mode, 0o777) == 0o700
    assert File.dir?(Home.workspaces_dir(home))
    assert Home.database_path(home) == Path.join(home, "consigliere.db")
  end

  test "boss_socket_path/1 joins the home dir with boss.sock" do
    assert Home.boss_socket_path("/tmp/xyz") == "/tmp/xyz/boss.sock"
  end
end
