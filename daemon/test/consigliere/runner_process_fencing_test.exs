defmodule Consigliere.RunnerProcessFencingTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerProcess

  test "stdout_chunk with a stale fencing_token is ignored" do
    heartbeat_file =
      Path.join(System.tmp_dir!(), "fence-#{System.unique_integer([:positive])}.hb")

    attempt_id = "fence-#{System.unique_integer([:positive])}"
    token = "live-#{attempt_id}"

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: attempt_id,
        heartbeat_file: heartbeat_file,
        fencing_token: token
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(heartbeat_file)
    end)

    Process.sleep(150)
    before = RunnerProcess.heartbeat_count(pid)
    %{session: %{socket: socket}} = :sys.get_state(pid)

    stale =
      JSON.encode!(%{
        "type" => "stdout_chunk",
        "fencing_token" => "stale-#{attempt_id}",
        "data" => String.duplicate("stale\n", 80)
      })

    send(pid, {:tcp, socket, stale <> "\n"})
    Process.sleep(80)

    assert RunnerProcess.heartbeat_count(pid) < before + 20,
           "a stale fencing token must not create heartbeat state"

    live =
      JSON.encode!(%{
        "type" => "stdout_chunk",
        "fencing_token" => token,
        "data" => String.duplicate("live\n", 80)
      })

    send(pid, {:tcp, socket, live <> "\n"})
    Process.sleep(80)

    assert RunnerProcess.heartbeat_count(pid) >= before + 80
  end
end
