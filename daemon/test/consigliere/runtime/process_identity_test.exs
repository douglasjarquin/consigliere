defmodule Consigliere.Runtime.ProcessIdentityTest do
  use ExUnit.Case, async: false

  alias Consigliere.Runtime.ProcessIdentity

  test "does not trust the expected hash for a same-basename process" do
    directory =
      Path.join(System.tmp_dir!(), "process-identity-#{System.unique_integer([:positive])}")

    impostor = Path.join(directory, "sleep")
    executable = System.find_executable("sleep") || "/bin/sleep"

    File.mkdir_p!(directory)
    File.cp!(System.find_executable("sh") || "/bin/sh", impostor)
    File.chmod!(impostor, 0o700)

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, args: [~c"30"]]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)

    expected_hash =
      impostor |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    on_exit(fn ->
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
      File.rm_rf(directory)
    end)

    assert ProcessIdentity.verify(pid, impostor, expected_hash) == :identity_mismatch
  end

  test "verifies the live executable path and hash" do
    executable = System.find_executable("sleep") || "/bin/sleep"
    {hash_output, 0} = System.cmd("shasum", ["-a", "256", executable])
    [expected_hash | _] = String.split(String.trim(hash_output))

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, args: [~c"30"]]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    assert ProcessIdentity.verify(pid, executable, expected_hash) == :verified
  end
end
