defmodule Consigliere.Runtime.CommandTest do
  use ExUnit.Case, async: false

  alias Consigliere.Runtime.Command

  test "a hung native observer returns within its caller deadline" do
    executable = System.find_executable("sleep") || "/bin/sleep"
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :timeout, _output} =
             Command.run(executable, ["30"], timeout_ms: 50)

    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end

  test "bounds one oversized native command chunk before flattening it" do
    parent = self()
    executable = System.find_executable("head") || "/usr/bin/head"

    pid =
      spawn(fn ->
        Process.flag(:max_heap_size, %{size: 600_000, kill: true, error_logger: false})

        send(
          parent,
          {:result,
           Command.run(executable, ["-c", "200000", "/dev/zero"],
             max_output: 65_536,
             timeout_ms: 2_000
           )}
        )
      end)

    ref = Process.monitor(pid)

    receive do
      {:result, {:error, :output_too_large, output}} ->
        assert byte_size(output) == 65_536

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("oversized native command exited before a bounded result: #{inspect(reason)}")
    after
      5_000 ->
        flunk("oversized native command did not return a bounded result")
    end
  end
end
