defmodule Consigliere.ProjectVerificationsCommandTest do
  use ExUnit.Case, async: false

  alias Consigliere.ProjectVerifications.Command

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "cs-verification-command-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  test "passes literal argv without allowing shell interpolation", %{workspace: workspace} do
    marker = Path.join(workspace, "injected")

    assert %{outcome: "passed", output_bytes: bytes} =
             Command.run(["printf", "safe; touch #{marker}"], workspace)

    assert bytes == byte_size("safe; touch #{marker}")
    refute File.exists?(marker)
  end

  test "returns a bounded timeout outcome", %{workspace: workspace} do
    assert %{
             outcome: "infrastructure_error",
             timed_out: true,
             error_code: "timeout"
           } = Command.run(["sleep", "1"], workspace, timeout_ms: 25, total_timeout_ms: 100)
  end

  test "combines stderr into the bounded command result", %{workspace: workspace} do
    assert %{outcome: "failed", output_bytes: output_bytes} =
             Command.run(["sh", "-c", "printf stderr-only >&2; exit 7"], workspace)

    assert output_bytes == byte_size("stderr-only")
  end

  test "enforces total timeout from command start", %{workspace: workspace} do
    started_at = System.monotonic_time(:millisecond)

    assert %{outcome: "infrastructure_error", timed_out: true, error_code: "timeout"} =
             Command.run(
               ["sh", "-c", "sleep 0.04; printf started; sleep 1"],
               workspace,
               timeout_ms: 500,
               total_timeout_ms: 50
             )

    assert System.monotonic_time(:millisecond) - started_at < 250
  end

  test "timeout terminates the owned process group and its child", %{workspace: workspace} do
    child_pid_path = Path.join(workspace, "child.pid")

    assert %{outcome: "infrastructure_error", timed_out: true} =
             Command.run(
               ["sh", "-c", "sleep 30 & echo $! > #{child_pid_path}; wait"],
               workspace,
               timeout_ms: 250,
               total_timeout_ms: 500
             )

    child_pid = workspace |> Path.join("child.pid") |> File.read!() |> String.trim()
    assert {_, 1} = System.cmd("kill", ["-0", child_pid], stderr_to_stdout: true)
  end

  test "returns a bounded output outcome", %{workspace: workspace} do
    assert %{
             outcome: "infrastructure_error",
             timed_out: false,
             error_code: "output_too_large",
             output_bytes: output_bytes
           } = Command.run(["seq", "1", "30000"], workspace, total_timeout_ms: 2_000)

    assert output_bytes <= 65_536
  end

  test "bounds one oversized command output before accumulating it", %{workspace: workspace} do
    parent = self()

    pid =
      spawn(fn ->
        Process.flag(:max_heap_size, %{size: 600_000, kill: true, error_logger: false})

        send(
          parent,
          {:result,
           Command.run(
             ["head", "-c", "200000", "/dev/zero"],
             workspace,
             total_timeout_ms: 2_000
           )}
        )
      end)

    ref = Process.monitor(pid)

    receive do
      {:result, %{outcome: "infrastructure_error", error_code: "output_too_large"} = result} ->
        assert result.output_bytes == 65_536

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk(
          "oversized command process exited before returning a bounded result: #{inspect(reason)}"
        )
    after
      5_000 ->
        flunk("oversized command did not return a bounded result")
    end
  end

  test "does not inherit unlisted environment variables", %{workspace: workspace} do
    System.put_env("CS_SYNTHETIC_SECRET", "must-not-cross")

    on_exit(fn -> System.delete_env("CS_SYNTHETIC_SECRET") end)

    assert %{outcome: "passed", output_bytes: 0} =
             Command.run(["sh", "-c", "printf %s \"$CS_SYNTHETIC_SECRET\""], workspace)
  end
end
