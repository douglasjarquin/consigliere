defmodule Consigliere.RunnerProcessEnvTest do
  use ExUnit.Case, async: false

  alias Consigliere.RunnerProcess

  test "the harness environment does not include CS_HOME or adapter credentials" do
    secret_home = Path.join(System.tmp_dir!(), "cs-secret-#{System.unique_integer([:positive])}")
    File.mkdir_p!(secret_home)
    File.write!(Path.join(secret_home, "sqlite.db"), "not for agents\n")

    previous = %{
      "CS_HOME" => System.get_env("CS_HOME"),
      "GITHUB_TOKEN" => System.get_env("GITHUB_TOKEN"),
      "LINEAR_API_KEY" => System.get_env("LINEAR_API_KEY")
    }

    System.put_env("CS_HOME", secret_home)
    System.put_env("GITHUB_TOKEN", "gh-secret")
    System.put_env("LINEAR_API_KEY", "lin-secret")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf(secret_home)
    end)

    out = Path.join(System.tmp_dir!(), "env-#{System.unique_integer([:positive])}.out")
    heartbeat_file = Path.join(System.tmp_dir!(), "env-#{System.unique_integer([:positive])}.hb")

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: "env-#{System.unique_integer([:positive])}",
        heartbeat_file: heartbeat_file,
        harness_command: [
          "sh",
          "-c",
          "(printenv CS_HOME; printenv GITHUB_TOKEN; printenv LINEAR_API_KEY; true) > '#{out}' 2>/dev/null; sleep 5"
        ]
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(out)
      File.rm(heartbeat_file)
    end)

    wait_for_file(out)

    leaked = String.trim(File.read!(out))

    assert leaked == "",
           "harness saw secrets #{inspect(leaked)} (CS_HOME and adapter credentials must not leak)"
  end

  test "CODEX_HOME is forwarded and does not contain boss or sqlite files" do
    home = Path.join(System.tmp_dir!(), "cs-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "credentials"))
    File.write!(Path.join(home, "credentials/boss"), "boss-secret\n")
    File.write!(Path.join(home, "consigliere.db"), "sqlite\n")
    previous = System.get_env("CS_HOME")
    System.put_env("CS_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("CS_HOME", previous), else: System.delete_env("CS_HOME")
      File.rm_rf(home)
    end)

    dest = Consigliere.Home.ensure_codex_home!(home)
    refute File.exists?(Path.join(dest, "boss"))
    refute File.exists?(Path.join(dest, "consigliere.db"))

    out = Path.join(System.tmp_dir!(), "codex-env-#{System.unique_integer([:positive])}.out")

    heartbeat_file =
      Path.join(System.tmp_dir!(), "codex-env-#{System.unique_integer([:positive])}.hb")

    {:ok, pid} =
      RunnerProcess.start_link(
        attempt_id: "env-#{System.unique_integer([:positive])}",
        heartbeat_file: heartbeat_file,
        harness_command: [
          "sh",
          "-c",
          "(printenv CODEX_HOME; printenv CS_HOME; printenv GITHUB_TOKEN; true) > '#{out}' 2>/dev/null; sleep 5"
        ]
      )

    os_pid = RunnerProcess.os_pid(pid)

    on_exit(fn ->
      Consigliere.ProcessHelpers.kill_and_verify_dead(os_pid)
      File.rm(out)
      File.rm(heartbeat_file)
    end)

    wait_for_file(out)
    lines = File.read!(out) |> String.split("\n", trim: true)
    assert dest in lines
    refute home in lines
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
