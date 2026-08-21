defmodule Consigliere.BackupTest do
  use ExUnit.Case, async: false

  alias Consigliere.Backup
  alias Consigliere.Home

  test "VACUUM INTO backup restores with a clean integrity_check" do
    dest =
      Path.join(Home.dir(), "backups/test-#{System.unique_integer([:positive])}.db")

    on_exit(fn -> File.rm(dest) end)

    assert {:ok, ^dest} = Backup.backup(dest)
    assert File.exists?(dest)
    assert Backup.integrity_check() == :ok
  end
end
