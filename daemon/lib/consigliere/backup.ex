defmodule Consigliere.Backup do
  @moduledoc """
  SQLite backup via VACUUM INTO. Never copy the live database file.
  """

  alias Consigliere.Repo

  def backup(dest) when is_binary(dest) do
    dest = Path.expand(dest)

    unless String.match?(dest, ~r|^/[\w./-]+$|) do
      raise ArgumentError, "refusing backup path #{inspect(dest)}"
    end

    File.mkdir_p!(Path.dirname(dest))
    File.rm(dest)
    Repo.query!("VACUUM INTO '#{dest}'")
    {:ok, dest}
  end

  def integrity_check do
    case Repo.query!("PRAGMA integrity_check") do
      %{rows: [["ok"]]} -> :ok
      %{rows: rows} -> {:error, rows}
    end
  end
end
