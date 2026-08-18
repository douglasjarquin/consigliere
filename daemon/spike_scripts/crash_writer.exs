alias Consigliere.Repo
alias Consigliere.DatabaseWriter

IO.puts("crash_writer: started, pid=#{System.pid()}")

for i <- 1..1_000_000 do
  DatabaseWriter.insert_mission(%{title: "crash-test-#{i}", phase: "draft"})
  if rem(i, 50) == 0, do: IO.puts("crash_writer: committed through #{i}")
end
