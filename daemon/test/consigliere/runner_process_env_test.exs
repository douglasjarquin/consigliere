defmodule Consigliere.RunnerProcessEnvTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerProcess

  test "the harness environment does not include CS_HOME" do
    secret_home = Path.join(System.tmp_dir!(), "cs-secret-#{System.unique_integer([:positive])}")
    File.mkdir_p!(secret_home)
    File.write!(Path.join(secret_home, "sqlite.db"), "not for agents\n")

    previous = System.get_env("CS_HOME")
    System.put_env("CS_HOME", secret_home)

    on_exit(fn ->
      if previous, do: System.put_env("CS_HOME", previous), else: System.delete_env("CS_HOME")
      File.rm_rf(secret_home)
    end)

    out = Path.join(System.tmp_dir!(), "env-#{System.unique_integer([:positive])}.out")
    heartbeat_file = Path.join(System.tmp_dir!(), "env-#{System.unique_integer([:positive])}.hb")

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: "env-#{System.unique_integer([:positive])}",
        heartbeat_file: heartbeat_file,
        harness_command: ["sh", "-c", "(printenv CS_HOME || true) > '#{out}'; sleep 5"]
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(out)
      File.rm(heartbeat_file)
    end)

    wait_for_file(out)

    assert String.trim(File.read!(out)) == "",
           "harness saw CS_HOME=#{inspect(File.read!(out))} (daemon home must not leak)"
  end

  defp wait_for_file(path, attempts \\ 50) do
    cond do
      File.exists?(path) ->
        :ok

      attempts > 0 ->
        Process.sleep(50)
        wait_for_file(path, attempts - 1)

      true ->
        flunk("harness never wrote #{path}")
    end
  end
end
