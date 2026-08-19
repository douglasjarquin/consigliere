alias Consigliere.{
  RunnerDynamicSupervisor,
  MissionDynamicSupervisor,
  MissionCoordinator,
  RunnerProcess
}

heartbeat_file = Path.join(System.tmp_dir!(), "spike-b-tmux-driver.hb")
attempt_id = "tmux-attempt-1"
mission_id = "tmux-mission-1"

{:ok, _} =
  DynamicSupervisor.start_child(
    RunnerDynamicSupervisor,
    {RunnerProcess, attempt_id: attempt_id, heartbeat_file: heartbeat_file}
  )

{:ok, _mission_supervisor_pid} =
  MissionDynamicSupervisor.start_mission(mission_id: mission_id, attempt_id: attempt_id)

[{coordinator_pid, _}] = Registry.lookup(Consigliere.Registry, {:mission, mission_id})
[{runner_pid, _}] = Registry.lookup(Consigliere.Registry, {:runner, attempt_id})
os_pid = RunnerProcess.os_pid(runner_pid)

IO.puts("DRIVER: runner BEAM pid=#{inspect(runner_pid)} os_pid=#{os_pid}")
IO.puts("DRIVER: coordinator BEAM pid (before kill)=#{inspect(coordinator_pid)}")

Process.sleep(500)
IO.puts("DRIVER: heartbeat_count before kill = #{RunnerProcess.heartbeat_count(runner_pid)}")

ref = Process.monitor(coordinator_pid)
Process.exit(coordinator_pid, :kill)

receive do
  {:DOWN, ^ref, :process, ^coordinator_pid, reason} ->
    IO.puts("DRIVER: coordinator confirmed killed, reason=#{inspect(reason)}")
end

Process.sleep(500)

IO.puts("DRIVER: runner still Process.alive? = #{Process.alive?(runner_pid)}")
IO.puts("DRIVER: heartbeat_count after kill = #{RunnerProcess.heartbeat_count(runner_pid)}")

case Registry.lookup(Consigliere.Registry, {:mission, mission_id}) do
  [{new_coordinator_pid, _}] ->
    IO.puts(
      "DRIVER: restarted coordinator BEAM pid=#{inspect(new_coordinator_pid)} (different from pre-kill pid, i.e. a real restart happened? #{new_coordinator_pid != coordinator_pid})"
    )

    reattached_runner_pid = MissionCoordinator.runner_pid(new_coordinator_pid)

    IO.puts(
      "DRIVER: restarted coordinator's runner_pid=#{inspect(reattached_runner_pid)} (matches original runner? #{reattached_runner_pid == runner_pid})"
    )

  [] ->
    IO.puts("DRIVER: FAIL - no restarted coordinator found in registry")
end

reattached_os_pid = RunnerProcess.os_pid(runner_pid)

IO.puts(
  "DRIVER: os_pid after coordinator restart=#{reattached_os_pid} (matches original? #{reattached_os_pid == os_pid})"
)

System.cmd("sh", [
  "-c",
  "kill -0 #{os_pid} && echo 'DRIVER: kill -0 confirms OS process still alive' || echo 'DRIVER: FAIL os process is dead'"
])
|> elem(0)
|> IO.puts()

IO.puts("DRIVER: DONE os_pid=#{os_pid} runner_pid=#{inspect(runner_pid)}")

DynamicSupervisor.terminate_child(RunnerDynamicSupervisor, runner_pid)
System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)

wait_dead = fn wait_dead, attempts ->
  case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
    {_, 0} when attempts > 0 ->
      Process.sleep(50)
      wait_dead.(wait_dead, attempts - 1)

    {_, 0} ->
      raise "os_pid #{os_pid} never died"

    _ ->
      :ok
  end
end

wait_dead.(wait_dead, 20)
File.rm(heartbeat_file)
IO.puts("DRIVER: cleanup complete, os_pid=#{os_pid} verified dead, heartbeat_file removed")
