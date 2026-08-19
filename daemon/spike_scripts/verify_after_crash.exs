alias Consigliere.Repo

{:ok, %{rows: [[integrity]]}} = Repo.query("PRAGMA integrity_check")
IO.puts("integrity_check: #{integrity}")

{:ok, %{rows: [[count]]}} =
  Repo.query("SELECT COUNT(*) FROM missions WHERE title LIKE 'crash-test-%'")

IO.puts("committed_crash_test_rows: #{count}")

{:ok, %{rows: [[torn]]}} =
  Repo.query(
    "SELECT COUNT(*) FROM missions WHERE title LIKE 'crash-test-%' AND (phase IS NULL OR inserted_at IS NULL)"
  )

IO.puts("torn_rows: #{torn}")
