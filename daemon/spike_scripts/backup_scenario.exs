alias Consigliere.Repo
alias Consigliere.DatabaseWriter

for i <- 1..500 do
  DatabaseWriter.insert_mission(%{
    objective: "backup-test-#{i}",
    scope: "scope",
    acceptance_criteria: "criteria",
    phase: "draft"
  })
end

{:ok, %{rows: [[total_before]]}} = Repo.query("SELECT COUNT(*) FROM missions")
IO.puts("total_rows_before_backup: #{total_before}")

backup_path = Path.expand("priv/vacuum_backup.db", File.cwd!())
File.rm(backup_path)
{:ok, _} = Repo.query("VACUUM INTO '#{backup_path}'")
IO.puts("vacuum_into_wrote: #{backup_path}")

plain_copy_path = Path.expand("priv/plain_copy.db", File.cwd!())
File.cp!(Path.expand("priv/consigliere_dev.db", File.cwd!()), plain_copy_path)
IO.puts("plain_copy_wrote: #{plain_copy_path}")
